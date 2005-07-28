# vcl2py:  Convert Vocola voice command files to NatLink Python "grammar"
#          classes implementing the voice commands
#
# Usage:  perl vcl2py.pl [-f] inputFileOrFolder outputFolder
# Where:
#   -f -- force processing even if file(s) not out of date
#
# This file is copyright (c) 2002-2003 by Rick Mohr. It may be redistributed 
# in any way as long as this copyright notice remains.
#
# 04/12/2003 Case insensitive window title comparisons
#            Output e.g. "emacs_vcl.py" (don't clobber existing NatLink files)
# 11/24/2002 Option to process a single file, or only changed files
# 10/12/2002 Use <any>+ instead of exporting individual NatLink commands
# 10/05/2002 Generalized indenting, emit()
# 09/29/2002 Built-in function: Repeat() 
# 09/15/2002 User-defined functions
# 08/17/2002 Use recursive grammar for command sequences
# 07/14/2002 Context statements can contain '|'
#            Support environment variable references in include statements
# 07/06/2002 Function arguments allow multiple actions
#            Built-in function: Eval()!
# 07/05/2002 New code generation using VocolaUtils.py
# 07/04/2002 Improve generated code: use "elif" in menus
# 06/02/2002 Command sequences!
# 05/19/2002 Support "include" statement
# 05/03/2002 Version 1.1
# 05/03/2002 Handle application names containing '_'
# 05/03/2002 Convert '\' to '\\' early to avoid quotewords bug
# 02/18/2002 Version 0.9
# 12/08/2001 convert e.g. "{Tab_2}" to "{Tab 2}"
#            expand in-string references (e.g. "{Up $1}")
# 03/31/2001 Detect and report unbalanced quotes
# 03/06/2001 Improve error checking for complex menus
# 02/24/2001 Change name to Vocola
# 02/18/2001 Handle terms containing an apostrophe
# 02/06/2001 Machine-specific command files
# 02/04/2001 Error on undefined variable or reference out of range
# 08/22/2000 First usable version

# Style notes:
#   Global variables are capitalized (e.g. $Definitions)
#   Local variables are lowercase (e.g. $in_folder)

use Text::ParseWords;    # for quotewords
use File::Basename;      # for fileparse
use File::stat;          # for mtime

# ---------------------------------------------------------------------------
# Main control flow

sub main
{
    $VocolaVersion = "2.4";
    $Debug = 0;  # 0 = no info, 1 = show statements, 2 = detailed info
    $Error_encountered = 0;
    $| = 1;      # flush output after every print statement

    $Process_all_files = 0;
    if ($ARGV[0] eq "-f") {
        $Force_processing = 1;
        shift @ARGV;
    }

    my ($input, $out_folder);
    if (@ARGV == 2) {
        $input = $ARGV[0];
        $out_folder = $ARGV[1];
    } else {
        die "Usage: perl vcl2py.pl [-f] inputFileOrFolder outputFolder\n";
    }

    my $in_file = "";
    if (-d $input) {
        # Input is an entire folder
        $In_folder = $ARGV[0];
    } elsif (-e $input) {
        # Input is a single file
        ($in_file, $In_folder, $extension) = fileparse($input, ".vcl");
        $extension eq ".vcl"
            or die "Input filename '$input' must end in '.vcl'\n";
    } else {
        die "Unknown input filename '$input'\n";
    }

    my $log_file = "$In_folder\\vcl2py_log.txt";
    open LOG, ">$log_file" or die "$@ $log_file\n";
    convert_files($in_file, $out_folder);
    close LOG;

    if ($Error_encountered == 0) {
        system("del \"$log_file\"");
    }
    exit($Error_encountered);
}

sub convert_files
{
    my ($in_file, $out_folder) = @_;
    if ($in_file ne "") {
        # Convert one file
        print "Converting $in_file...\n";
        convert_file($in_file, $out_folder);
    } else {
        # Convert each .vcl file in folder 
        opendir FOLDER, "$In_folder"
            or die "Couldn't open folder '$In_folder'\n";
        my $machine = lc($ENV{COMPUTERNAME});
        foreach (readdir FOLDER) {
            if (/^(.+)\.vcl$/) {
                my $in_file = lc($1);
                # skip machine-specific files for different machines
                next if ($in_file =~ /\@(.+)/ and $1 ne $machine);
                convert_file($in_file, $out_folder);
            }
        }
    }
}

# Convert one Vocola command file to a .py file

sub convert_file
{
    my ($in_file, $out_folder) = @_;
    my $out_file = $in_file;
    $out_file =~ s/[\@]/_/;
    $out_file =~ s/[-]/_/g;

    # The global $Module_name is used below to implement application-specific 
    # commands in the output Python
    $Module_name = lc($out_file);
    # The global $Input_name is used below for error logging
    $Input_name = "$in_file.vcl";
    $out_file = "$out_folder/$out_file" . "_vcl.py";

    $in_stats  = stat("$In_folder/$Input_name");
    $out_stats = stat("$out_file");
    $in_date  = $in_stats->mtime;
    $out_date = $out_stats ? $out_stats->mtime : 0;
    return unless $in_date > $out_date || $Force_processing;

    %Definitions = ();
    %Functions = ();
    @Forward_references = ();
    @Included_files = ();
    @Include_stack = ();
    $Error_count = 0;
    $File_empty = 1;
    $Statement_count = 1;

    if ($Debug>=1) {print LOG "\n==============================\n";}

    my @statements = parse_file($Input_name);
    &check_forward_references;

    # Prepend a "global" context statement if necessary
    if ($statements[0]->{TYPE} ne "context") {
        my $context = parse_context(": ");
        unshift(@statements, $context);
    }

    #print_statements (*LOG, @statements);
    if ($Error_count) {
        my $s = ($Error_count == 1) ? "" : "s";
        print LOG "  $Error_count error$s -- file not converted.\n";
        $Error_encountered = 1;
        return;
    }
    if ($File_empty) {
        # Write empty output file, for modification time comparisons 
        open OUT, ">$out_file" or die "$@ $out_file\n";
        close OUT;
        print LOG "Converting $Input_name\n";
        print LOG "  Warning: no commands in file.\n";
        return;
    }
    emit_output($out_file, @statements);
}

# ---------------------------------------------------------------------------
# Parsing routines
#
# The following grammar defines the Vocola language:
# (note that a "menu" is called an "alternative set" in the documentation)
#
#     statements = (context | definition | function | directive | top_command)*
#
#        context = chars* ('|' chars*)* ':'
#     definition = variable ':=' menu_body ';'
#       function = prototype ':=' action* ';'
#      directive = ('include' | 'sequence') word ';'
#    top_command = terms '=' action* ';'
#
#        command = terms ['=' action*]
#          terms = (term | '[' simple_term ']')+
#           term = simple_term | range | menu
#    simple_term = word | variable
#         action = word | call | reference
#
#           menu = '(' menuBody ')'
#       menuBody = command ('|' command)*
#
#           word = chars | '"' chars '"' |  "'" chars "'"
#       variable = '<' name '>'
#          range = number '..' number
#      reference = '$' (number | name)
#
#      prototype = functionName '(' formals ')'
#        formals = [name (',' name)*]
#           call = functionName '(' arguments ')'
#      arguments = [action (',' action)*]
#
# The parser works as follows:
#     1) Strip comments
#     2) Find statement segments by slicing at major delimiters (: ; :=)
#     3) Parse each segment using recursive descent
#
# The parse tree is built from three kinds of nodes (statement, term, 
# and action), using the following fields:
#
# statement: 
#    TYPE - command/definition/function/context/sequence
#    command:
#       NAME    - unique number
#       TERMS   - list of "term" structures
#       ACTIONS - list of "action" structures
#    definition:
#       NAME    - name of variable being defined
#       MENU    - "menu" structure defining alternatives
#    function:
#       NAME    - name of function being defined
#       FORMALS - list of argument names
#       ACTIONS - list of "action" structures
#    context:
#       STRINGS - list of strings to use in context matching
#       RULENAMES - list of rule names defined for this context
#    sequence:
#       TEXT    - yes or no
# 
# term:
#    TYPE   - word/variable/range/menu
#    NUMBER - sequence number of this term
#    word:
#       TEXT     - text defining the word(s)
#       OPTIONAL - is this word optional
#    variable:
#       TEXT     - name of variable being referenced
#       OPTIONAL - is this variable optional
#    range:
#       FROM     - start number of range
#       TO       - end number of range
#    menu:
#       COMMANDS - list of "command" structures defining the menu
#       
# action:
#    TYPE - word/reference/formalref/call
#    word:
#       TEXT      - keystrokes to send
#    reference:
#       TEXT      - keystrokes to send
#    formalref:
#       TEXT      - name of formal (i.e. user function argument) referenced
#    call:
#       TEXT      - name of function called
#       CALLTYPE  - dragon/vocola/user
#       ARGUMENTS - list of lists of actions, to be passed in call

# ---------------------------------------------------------------------------
# Built in Dragon and Vocola functions
# with number of expected arguments (-1 means a variable number)

%Vocola_functions = (
                     Eval              => 1,
                     Repeat            => 2,
                     );

%Dragon_functions = (
                     ActiveControlPick => 1,
                     ActiveMenuPick    => 1,
                     AppBringUp        => -1,
                     AppSwapWith       => 1,
                     Beep              => 0,
                     ButtonClick       => -1,
                     ClearDesktop      => 0,
                     ControlPick       => 1,
                     DdeExecute        => -1,
                     DdePoke           => 4,
                     DllCall           => -1,
                     DragToPoint       => -1,
                     GoToSleep         => 0,
                     HeardWord         => -1,
                     MenuCancel        => 1,
                     MenuPick          => 1,
                     MouseGrid         => -1,
                     MsgBoxConfirm     => 3,
                     PlaySound         => 1,
                     RememberPoint     => 0,
                     RunScriptFile     => 1,
                     SendKeys          => 1,
                     SendSystemKeys    => -1,
                     SetMicrophone     => -1,
                     SetMousePosition  => -1,
                     SetNaturalText    => 1,
                     ShellExecute      => -1,
                     ShiftKey          => -1,
                     TTSPlayString     => -1,
                     Wait              => 1,
                     WakeUp            => 1,
                     WinHelp           => -1,
                     );

# parse_file returns a parse tree (list of statements), which includes in-line
# any statements from include files. Since parse_file is called recursively
# for include files, all code applying to the parse tree as a whole is
# executed in this routine.

sub parse_file    # returns a list of statements
{
    my $in_file = shift;
    push(@Included_files, $in_file);
    push(@Include_stack, $in_file);
    $in_file = "$In_folder/$in_file";
    $Line_number = -1;
    my $text = read_file($in_file);

    # For python output we'll need to convert '\' to '\\'.  Do it up front so
    # quotewords won't miss '\;', e.g. in 'Kill White Space = {Esc}\;'
    $text =~ s.\\.\\\\.g;

    # Find statement segments by slicing at major delimiters (: ; :=)
    my @segments = quotewords(":=|:\\s|;", "delimiters", ($text));

    # Check for unbalanced quotes (because quotewords gives up )-:
    if (not @segments and $Line_number = has_unbalanced_quote($text)) {
        log_error("Unbalanced quote");
        return;
    }

    $Line_number = 1;
    my @statements = parse_statements(@segments);
    pop(@Include_stack);
    return @statements;
}

sub read_file     # return string, stripped of comments 
{
    my $in_file = shift;
    my @strings;
    open IN, "<$in_file" or log_error("Unable to open '$in_file'");
    while (<IN>) {
        if (/\#/) {
            # Line may contain a comment
            my @chunks = quotewords("\#", "delimiters", $_);
            push (@strings, $chunks[0]) if $chunks[0] ne "\#";
            push (@strings, "\n"      ) if @chunks > 1;
        } else {
            push (@strings, $_);
        }
    }
    close IN;
    join ('', @strings);
}

# This is the main parsing loop.
# Statement segments are in the global argument array @_
# Segments will be removed as they are parsed by parse_ routines

sub parse_statements    # statements = (context | top_command | definition)*
{
    my (@statements, $statement);

    while (@_ > 1)  # while segment array is not empty...
    {
        @Variable_terms = ();  # used in error-checking
        @Formals = ();
        eval { $statement = (&parse_context or
                             &parse_definition or
                             &parse_top_command or
                             &parse_directive)
               };
        if    ($@)             {log_error($@)}  # Catch calls to "die"
        elsif (not $statement) {log_error("Illegal statement: '@_[0]'"); shift}
        else {
            # Got a valid statement
            if ($statement->{TYPE} eq "definition") {
                my $name = $statement->{NAME};
                if ($Definitions{$name}) {log_error("Redefinition of <$name>")}
                $Definitions{$name} = $statement;
            } elsif ($statement->{TYPE} eq "command") {
                $statement->{NAME} = $Statement_count++;
            }

            if ($statement->{TYPE} ne "include") {
                push (@statements, $statement);
            } else {
                # Handle include file
                my $include_file = expand_variables($statement->{TEXT});
                unless (already_included($include_file)) {
                    # Save context, get statements from include file, restore 
                    push (@Include_stack, $Line_number, \@_);
                    push (@statements, parse_file($include_file));
                    @_ = @{ pop(@Include_stack) };
                    $Line_number = pop(@Include_stack);
                }
            }
        }
    }
    if (@_[0] =~ /\S/) {
        &shift_delimiter;
        log_error("Missing final delimiter");
    }
    
    return @statements;
}

sub parse_context    # context = chars* ('|' chars*)* ':'
{
    if ($_[0] =~ /^:\s$/ or $_[1] =~ /^:\s$/) {
        my $statement = {};
        $statement->{TYPE} = "context";
        my @strings;
        if ($_[1] =~ /:\s/) {
            &shift_clause;
            if (/=/) {die "Context statement contains '=' (missing ';'?)\n"}
            while (1) {
                /\G\s*([^|]*)/gc;
                $string = $1;
                $string =~ s/\s+$//; # remove trailing whitespace
                push (@strings, lc($string));
                last unless /\G\|/gc;
            }
        } else {
            &shift_delimiter;
            push (@strings, "");
        }
        $statement->{STRINGS} = \@strings;
        if ($Debug>=1) {print_directive (*LOG, $statement)}
        return $statement;
    }
}

sub parse_definition
{
    if ($_[1] eq ":=" and $_[3] eq ";") {
        &shift_clause;
        my $statement = (&parse_variable_definition or
                         &parse_function_definition or
                         die "Illegal definition: '$_'\n");
        return $statement;
    }
}

sub parse_variable_definition    # definition = variable ':=' menu_body ';'
{
    if (/^\s*<(.*)>\s*$/) {
        my $statement = {};
        $statement->{TYPE} = "definition";
        $statement->{NAME} = $1;
        &shift_clause;
        my $menu = &parse_menu_body;
        &ensure_empty;
        if ($menu->{TYPE} eq "menu") {verify_referenced_menu($menu)};
        $statement->{MENU} = $menu;
        if ($Debug>=1) {print_definition (*LOG, $statement)}
        return $statement;
    }
}

sub parse_function_definition   # function = prototype ':=' action* ';'
                                # prototype = functionName '(' formals ')'
{
    if (/\G\s*([a-zA-Z]\w*?)\s*\((.*)\)/gc) {
        my $functionName = $1;
        my $formalsString = $2;
        if ($Debug>=2) {print LOG "Found function:  $functionName()\n"}
        my $statement = {};
        $statement->{TYPE} = "function";
        $statement->{NAME} = $functionName;
        my @formals = parse_formals($formalsString);
        $statement->{FORMALS} = \@formals;
        @Formals = @formals; # Used below in &parse_formal_reference
        &shift_clause;
        $statement->{ACTIONS} = &parse_actions;
        defined ($Functions{$functionName})
            and die "Redefinition of $functionName()\n";
        $Functions{$functionName} = @formals;  # remember number of formals
        if ($Debug>=1) {print_function_definition (*LOG, $statement)}
        return $statement;
    }
}

sub parse_formals    # formals = [name (',' name)*]
{
    my $formalsString = shift;
    my @formals = split /\s*,\s*/, $formalsString;
    my @safe_formals = ();
    for my $formal (@formals) {
        $formal =~ /^[a-zA-Z]\w*$/
            or die "Illegal formal: '$formal'";
        if ($Debug>=2) {print LOG "Found formal:  $formal\n"}
        push (@safe_formals, "_$formal");
    }
    return @safe_formals;
}

sub parse_top_command    # top_command = terms '=' action* ';'
{
    if ($_[1] eq ";" and $_[0] =~ /=/) {
        &shift_clause;
        my $statement = &parse_command;
        &ensure_empty;
        $statement->{TYPE} = "command";
        $File_empty = 0;
        if ($Debug>=1) {print_command (*LOG, $statement); print LOG "\n"}
        return $statement;
    }
}

sub parse_directive    # directive = ('include' | 'sequence') word ';'
{
    if ($_[1] eq ";") {
        &shift_clause;
        my $statement = {};
        $statement->{TYPE} = "include";
        if (/^\s*include\s+/gc) {
            my $word = &parse_word or die "Can't tell what to include\n";
            $statement->{TEXT} = $word->{TEXT};
            &ensure_empty;
        } else {die "Unrecognized statement\n"}
        if ($Debug>=1) {print_directive (*LOG, $statement)}
        return $statement;
    }
}

sub parse_command    # command = terms ['=' action*]
{
    my $terms = &parse_terms;
    return 0 unless $terms;
    my $command = {};
    $command->{TERMS} = $terms;

    # Count variable terms for range checking in &parse_reference
    @Variable_terms = get_variable_terms($command);

    if (/\G\s*=/gc) {
        $command->{ACTIONS} = &parse_actions;
    }
    return $command;
}

sub parse_terms    # terms = (term | '[' simple_term ']')+
{
    my (@terms, $term);
    my $all_optional = 1;
    while (1) {
        my $optional = /\G\s*\[/gc;
        if ($optional) {
            $term = &parse_simple_term;
            if    (not $term)       {die "Expected term after '['\n"}
            elsif (not /\G\s*\]/gc) {die "Missing ']'\n"}
        } else {
            $term = &parse_term;
        }
        if ($term) {
            $term->{OPTIONAL} = $optional;
            $all_optional = 0 if not $optional;
            push (@terms, $term);
        } elsif (not @terms) {
            return 0;
        } elsif ($all_optional) {
            die "Command terms may not all be optional\n";
        } else {
            return combine_terms(@terms);
        }
    }
}

sub combine_terms    # Combine adjacent "word" terms; number resulting terms
{
    my @terms;
    my $term_count = 0;
    while (@_) {
        my $term = shift;
        if (&is_required_word($term)) {
            while (@_ and &is_required_word) {
                $term->{TEXT} .= " " . shift->{TEXT};
            }
        }
        $term->{NUMBER} = $term_count++;
        push (@terms, $term);
    }
    return \@terms;
}

sub is_required_word {@_[0]->{TYPE} eq "word" and not @_[0]->{OPTIONAL}}

sub parse_term    #  term = simple_term | range | menu
                  # range = number '..' number
                  #  menu = '(' menuBody ')'
{
    my $term;
    if (/\G\s*\(/gc) {
        $term = &parse_menu_body;
        if (not /\G\s*\)/gc) {die "End of alternative set before ')'\n"}
        if ($Debug>=2) {print LOG "Found menu:  "; 
                        print_menu (*LOG, $term); print LOG "\n"}
    } elsif (/\G\s*(\d*)\.\.(\d*)/gc) {
        $term = {};
        $term->{TYPE} = "range";
        $term->{FROM} = $1;
        $term->{TO}   = $2;
        if ($Debug>=2) {print LOG "Found range:  $1..$2\n"}
    } else {
        $term = &parse_simple_term;
    }
    return $term;
}

sub parse_simple_term    # simple_term = words | variable
                         #    variable = '<' variableName '>'
{
    if (/\G\s*<(.*?)>/gc) {
        if ($Debug>=2) {print LOG "Found variable:  <$1>\n"}
        add_forward_reference($1) unless $Definitions{$1};
        return create_variable_node($1);
    } else {
        return &parse_word;
    }
}

sub create_variable_node
{
    my $term = {};
    $term->{TYPE} = "variable";
    $term->{TEXT} = shift;
    return $term
}

sub parse_menu_body    # menuBody = command ('|' command)*
{
    my $menu = {};
    my @commands;
    while (1) {
        my $command = &parse_command;
        if (not $command) {die "Empty alternative set\n"}
        push (@commands, $command);
        last unless /\G\s*\|/gc;
    }
    $menu->{TYPE} = "menu";
    $menu->{COMMANDS} = \@commands;
    return $menu;
}

sub parse_actions    # action = words | call | reference
{
    my @actions;
    while (my $action = (&parse_reference or &parse_call or &parse_word)) {
        if ($action->{TYPE} ne "word" || $action->{TEXT} eq "") {
            push (@actions, $action);
        } else {
            # convert e.g. "{Tab_2}" to "{Tab 2}"
            $action->{TEXT} =~ s/\{(.*?)_(.*?)\}/\{$1 $2\}/g;

            # expand in-string references (e.g. "{Up $1}")
            while ($action->{TEXT} =~ /\G(.*?)\$(\d+|[a-zA-Z]\w*)/gc) {
                my ($word, $ref) = ($1, $2);
                if ($word =~ /^(.*?)\\$/) {
                    # we had e.g. "\$1", so it wasn't a reference after all
                    $word = $1 . "\$" . $ref;
                    push (@actions, create_word_node($word, 1));
                } else {
                    push (@actions, create_word_node($word, 1)) if $word;
                    if ($ref =~ /\d+/) {
                        push (@actions, create_reference_node($ref));
                    } else {
                        push (@actions, create_formal_reference_node($ref));
                    }
                }
            }
            if ($action->{TEXT} =~ /\G(.+)/gc) {
                push (@actions, create_word_node($1, 1));
            }
        }
    }
    return \@actions;
}

sub parse_reference    # reference = '$' (number | name)
{
    if      (/\G\s*\$(\d+)/gc) {
        return create_reference_node($1);
    } elsif (/\G\s*\$([a-zA-Z]\w*)/gc) {
        return create_formal_reference_node($1);
    }
}

sub create_reference_node
{
    my $n = shift;
    if ($n > @Variable_terms) {die "Reference '\$$n' out of range\n"}
    my $term = $Variable_terms[$n - 1];
    if ($term->{TYPE} eq "menu") {verify_referenced_menu($term)};
    if ($Debug>=2) {print LOG "Found reference:  \$$n\n"}
    my $action = {};
    $action->{TYPE} = "reference";
    $action->{TEXT} = $n;
    return $action;
}

sub create_formal_reference_node
{
    my $name = shift;
    my $formal = "_" . $name;
    grep {$_ eq $formal} @Formals
        or die "Reference to unknown formal '\$$name'\n";
    if ($Debug>=2) {print LOG "Found formal reference:  \$$name\n"}
    my $action = {};
    $action->{TYPE} = "formalref";
    $action->{TEXT} = "$formal";
    return $action;
}

sub parse_call    # call = functionName '(' arguments ')'
{
    if (/\G\s*(\w+?)\s*\(/gc) {
        my $functionName = $1;
        if ($Debug>=2) {print LOG "Found call:  $functionName()\n"}
        my $action = {};
        $action->{TYPE} = "call";
        $action->{TEXT} = $functionName;
        $action->{ARGUMENTS} = &parse_arguments;
        if (not /\G\s*\)/gc) {die "Missing ')'\n"}
        my $nActuals = @{ $action->{ARGUMENTS} };
        my $nFormals;
        if (defined($nFormals = $Dragon_functions{$functionName})) {
            $action->{CALLTYPE} = "dragon";
        } elsif (defined($nFormals = $Vocola_functions{$functionName})) {
            $action->{CALLTYPE} = "vocola";
        } elsif (defined($nFormals = $Functions{$functionName})) {
            $action->{CALLTYPE} = "user";
        } else {
            die "Call to unknown function '$functionName'\n";
        }
        
        if ($nFormals != -1 and $nFormals != $nActuals) {
            die "In call to '$functionName', expected $nFormals argument(s) but found $nActuals\n";
        } 
        return $action;
    }
}

sub parse_arguments    # arguments = [action (',' action)*]
{
    my @arguments;
    my $argument = &parse_actions;
    return unless @{$argument};
    while (1) {
        push (@arguments, $argument);
        last unless /\G\s*,/gc;
        $argument = &parse_actions;
        if (not @{$argument}) {die "Missing or invalid argument\n"}
    }
    return \@arguments;
}

sub parse_word    # word = chars | '"' chars '"' |  "'" chars "'"
{
    if (   /\G\s*\"([^\"]*)\"\s*/gc      # "word"
        or /\G\s*\'([^\']*)\'\s*/gc      # 'word'
        or /\G\s*([^\s=()\[\]|,]+)/gc)   #  word
    {
        if ($Debug>=2) {print LOG "Found word:  '$1'\n"}
        return create_word_node($1, 0);
    }
}

sub create_word_node
{
    my $text = shift;
    my $substitute = shift;
    $text =~ s/\\\$/\$/g if $substitute;  # convert \$ to $
    my $term = {};
    $term->{TYPE} = "word";
    $term->{TEXT} = $text;
    return $term;
}

sub ensure_empty
{
    if (/\G\s*(\S+)/gc) {
        die "Unexpected text: '$1'\n";
    }
}

# The argument list contains a string we want to parse, followed by a 
# delimiter.  Splice them both out of the list, making the string the
# current argument ($_).  Also count newlines for error reporting.

sub shift_clause
{
    $_ = $_[0] . $_[1];
    $Line_number++ while (/\G.*?\n/gc);
    $_ = shift;
    shift;
}

sub shift_delimiter 
{
    $_ = shift;
    $Line_number++ while (/\G.*?\n/gc);
}

sub log_error
{
    print LOG "Converting $Input_name\n" unless $Error_count;
    print LOG &format_error_message;
    $Error_count++;
}

# Here is what the include stack looks like (growing downwards): 
#   name of top-level file 
#   line number of first include
#   segments pending after first include
#   name of first include file
#   line number of second include
#   segments pending after second include
#   name of second include file

sub format_error_message
{
    my $message = shift;
    chomp($message);
    my $last = $#Include_stack;
    my $line = $Line_number;
    if ($Line_number == -1) {
        # "Unable to open file" -- ignore top frame of include stack
        $line = $Include_stack[$last - 2];
        $last -= 3;
    }
    my $file_msg = ($last <= 0) ? "" : " of $Include_stack[$last]";
    $message = "  Error at line $line$file_msg:  $message\n";
    my $indent = "";
    for (my $i = $last; $i >= 3; $i -= 3) {
        my $line = $Include_stack[$i - 2];
        my $file = $Include_stack[$i - 3];
        $indent .= "  ";
        $message .= "$indent  (Included at line $line of $file)\n";
    }
    return $message;   
}

sub already_included
{
    # Return TRUE if $filename was already included in the current file
    my $filename = shift;
    for my $included (@Included_files) {
        return 1 if ($included eq $filename);
    }
    return 0;
}

sub expand_variables
{
    my $text = shift;
    while ($text =~ /\$(\w+)/) {
        my $variable = $1;
        my $value = $ENV{$variable};
        log_error("Reference to unknown variable $variable") unless $value;
        $text =~ s/\$$variable/$value/;
    }
    return $text;
    # need to handle \$. Should be a warning not an error.
}

# ---------------------------------------------------------------------------
# Check for unbalanced quotes

sub has_unbalanced_quote
{
    $_ = shift;
    my $line = 1;
    my $bad_line_guess = -1;
    while (/\G(.*?)([\'\"])(.*?)\2/gcs) {
        $line += count_lines($1);
        $bad_line_guess = $line if ($bad_line_guess == -1 and $3 =~ /=|;/);
        return $bad_line_guess if $1 =~ /[\'\"]/s;
        $line += count_lines($3);
    }
    if (/\G(.+)/gcs) {
        return $bad_line_guess if $1 =~ /[\'\"]/s;
    }
    return 0;
}

sub count_lines
{
    my $text = shift;
    my $line_count = 0;
    $line_count++ while $text =~ /\G.*?\n/gc;
    return $line_count
}

# ---------------------------------------------------------------------------
# Parse-time error checking of references

sub verify_referenced_menu
{
    my ($menu, $parent_has_actions) = @_;
    my @commands = @{ $menu->{COMMANDS} };
    for my $command (@commands) {
        my $has_actions = $parent_has_actions;
        my @actions = @{ $command->{ACTIONS} };
        if (@actions) {
            if ($parent_has_actions) {die "Actions may not be nested\n"}
            $has_actions = 1;
            # make sure no actions are references
            for my $action (@actions) {
                if ($action->{TYPE} eq "reference") {
                    die "Substitution may not contain a reference\n";
                }
            }
        }
        my @terms = @{ $command->{TERMS} };
        if (@terms > 1) {die "Alternative is too complex\n"}
        my $type = $terms[0]->{TYPE};
        if    ($type eq "menu"){verify_referenced_menu($terms[0],$has_actions)}
        elsif ($type eq "variable") {die "Alternative cannot be a variable\n"}
        elsif ($type eq "range") {
            # allow a single range with no actions
            return if (not $has_actions and @commands == 1);
            die "Alternative cannot be a range\n";
        }
    }
}

sub add_forward_reference
{
    my $variable = shift;
    my $forward_reference = {};
    $forward_reference->{VARIABLE} = $variable;
    $forward_reference->{MESSAGE} =
       format_error_message("Reference to undefined variable '<$variable>'\n");
    push (@Forward_references, $forward_reference);
}

sub check_forward_references
{
    for my $forward_reference (@Forward_references) {
        my $variable = $forward_reference->{VARIABLE};
        if (not $Definitions{$variable}) {
            print LOG $forward_reference->{MESSAGE};
            $Error_count++;
        }
    }
}

# ---------------------------------------------------------------------------
# Printing of data structures (for debugging)

sub print_statements
{
    my $out = shift;
    for my $statement (@_) {
        my $type = $statement->{TYPE};
        if ($type eq "context" || $type eq "include") {
            print_directive ($out, $statement);
        } elsif ($type eq "definition") {
            print_definition ($out, $statement);
        } elsif ($type eq "function") {
            print_function_definition ($out, $statement);
        } elsif ($type eq "command") {
            print $out "C$statement->{NAME}:  ";
            print_command ($out, $statement);
            print $out ";\n";
        }
    }
    print $out "\n";
}

sub print_directive
{
    my ($out, $statement) = @_;
    print $out "$statement->{TYPE}:  '$statement->{TEXT}'\n";
}

sub print_definition
{
    my ($out, $statement) = @_;
    print $out "<$statement->{NAME}> := ";
    print_menu ($out, $statement->{MENU});
    print $out ";\n";
}

sub print_function_definition
{
    my ($out, $statement) = @_;
    print $out "$statement->{NAME}(";
    print $out join(',', @{ $statement->{FORMALS} });
    print $out ") := ";
    print_actions ($out, @{ $statement->{ACTIONS} });
    print $out ";\n";
}

sub print_command
{
    my ($out, $command) = @_;
    print_terms ($out, @{ $command->{TERMS} });
    if ($command->{ACTIONS}) {
        print $out " = ";
        print_actions ($out, @{ $command->{ACTIONS} });
    }
}

sub print_terms
{
    my $out = shift;
    print_term($out, shift);
    for my $term (@_) {
        print $out " ";
        print_term($out, $term);
    }
}

sub print_term
{
    my ($out, $term) = @_;
    #print $out "$term->{NUMBER}:";
    if ($term->{OPTIONAL}) {print $out "["}
    if    ($term->{TYPE} eq "word")     {print $out "$term->{TEXT}"}
    elsif ($term->{TYPE} eq "variable") {print $out "<$term->{TEXT}>"}
    elsif ($term->{TYPE} eq "menu")     {print_menu ($out, $term)}
    elsif ($term->{TYPE} eq "range") {
        print $out "$term->{FROM}..$term->{TO}";
    }
    if ($term->{OPTIONAL}) {print $out "]"}
}

sub print_menu
{
    my $out = shift;
    my @commands = @{ shift->{COMMANDS} };
    print $out "(";
    print_command($out, shift @commands);
    for my $command (@commands) {
        print $out " | ";
        print_command($out, $command);
    }
    print $out ")";
}

sub print_actions
{
    my $out = shift;
    print_action($out, shift);
    for my $action (@_) {
        print $out " ";
        print_action($out, $action);
    }
}

sub print_action
{
    my ($out, $action) = @_;
    if    ($action->{TYPE} eq "word")     {print $out "$action->{TEXT}"}
    elsif ($action->{TYPE} eq "reference"){print $out "\$$action->{TEXT}"}
    elsif ($action->{TYPE} eq "formalref"){print $out "\$$action->{TEXT}"}
    elsif ($action->{TYPE} eq "call") {
        print $out "$action->{TEXT}(";
        if (my @arguments = @{ $action->{ARGUMENTS} }) {
            print_argument($out, shift @arguments);
            for my $argument (@arguments) {
                print $out ", ";
                print_argument($out, $argument);
            }
        }
        print $out ")";
    }
}

sub print_argument
{
    my ($out, $argument) = @_;
    print_actions($out, @{$argument});
}

# ---------------------------------------------------------------------------
# Emit NatLink output

sub emit_output
{
    my ($out_file, @statements) = @_;
    open OUT, ">$out_file" or die "$@ $out_file\n";
    &emit_file_header;
    for my $statement (@statements) {
        my $type = $statement->{TYPE};
        if    ($type eq "definition") {emit_definition_grammar ($statement)}
        elsif ($type eq "command")    {emit_command_grammar ($statement)}
    }
    &emit_sequence_and_context_code;
    for my $statement (@statements) {
        my $type = $statement->{TYPE};
        if    ($type eq "definition") {emit_definition_actions ($statement)}
        if    ($type eq "function")   {emit_function_actions ($statement)}
        elsif ($type eq "command")    {emit_top_command_actions ($statement)}
    }
    &emit_file_trailer;
    close OUT;
}

sub emit_sequence_and_context_code
{
    # Build a list of context statements, and commands defined in each
    my (@contexts, $context);
    for my $statement (@_) {
        my $type = $statement->{TYPE};
        if ($type eq "context") {
            $context = $statement;
            push (@contexts, $context);
        } elsif ($type eq "command") {
            push (@{ $context->{RULENAMES} }, $statement->{NAME});
        }
    }
    emit_sequence_rules(@contexts);
    &emit_file_middle;
    emit_context_definitions(@contexts);
    emit_context_activations(@contexts);
}

sub emit_sequence_rules
{
    # Emit rules allowing speaking a sequence of commands
    # (and add them to the RULENAMES for the context in question)
    my $number = 0;
    my $any = "";
    for my $context (@_) {
        my @names = @{ $context->{RULENAMES} };
        next if @names == 0;
        $number++;
        my $suffix = "";
        my $rules = '<' . join('>|<', @names) . '>';
        my @strings = @{ $context->{STRINGS} };
        if ($strings[0] eq "") {
            emit(2, "<any> = $rules;\n");
            $any = "<any>|";
        } else {
            $suffix = "_set$number";
            emit(2, "<any$suffix> = $any$rules;\n");
        }
        my $rule_name = "sequence$suffix";
        $context->{RULENAMES} = [$rule_name];
        emit(2, "<$rule_name> exported = <any$suffix>+;\n");
    }
}

sub emit_context_definitions
{
    # Emit a "rule set" definition containing all command names in this context
    my $number = 0;
    for my $context (@_) {
        my @names = @{ $context->{RULENAMES} };
        next if @names == 0;
        $number++;
        my $first_name = shift @names;
        emit(2, "self.ruleSet$number = ['$first_name'");
        for my $name (@names) {print OUT ",'$name'"}
        emit(0, "]\n");
    }
}

sub emit_context_activations
{
    my $app = $Module_name;
    my $module_is_global = ($app =~ /^\_/);
    my $module_has_prefix = 0;
    if ($app =~ /^(.+?)_.*/) {
        $prefix = $1;
        $module_has_prefix = 1;
    }
    #emit(2, "self.activateAll()\n") if $module_is_global;
    emit(0, "\n    def gotBegin(self,moduleInfo):\n");
    if ($module_is_global) {
        emit(2, "window = moduleInfo[2]\n");
    } else {
        emit(2, "\# Return if wrong application\n");
        emit(2, "window = matchWindow(moduleInfo,'$app','')\n");
        if ($module_has_prefix) {
            emit(2, "if not window: window = matchWindow(moduleInfo,'$prefix','')\n");
        }
        emit(2, "if not window: return None\n");
    }
    emit(2, "self.firstWord = 0\n");
    emit(2, "\# Return if same window and title as before\n");
    emit(2, "if moduleInfo == self.currentModule: return None\n");
    emit(2, "self.currentModule = moduleInfo\n\n");
    emit(2, "self.deactivateAll()\n");
    emit(2, "title = string.lower(moduleInfo[1])\n");

    # Emit code to activate the context's commands if one of the context
    # strings matches the current window
    my $number = 0;
    for my $context (@_) {
        next if not $context->{RULENAMES};
        $number++;
        my $tests = join " or ", map {"string.find(title,'$_') >= 0"}
                                     @{ $context->{STRINGS} };
        emit(2, "if $tests:\n");
        emit(3, "for rule in self.ruleSet$number:\n");
        if ($module_is_global) {emit(4, "self.activate(rule)\n");}
        else                   {emit(4, "self.activate(rule,window)\n");}
    }
    emit(0, "\n");
}

#        if (not $module_is_global) {
#            emit(3, "    self.activate(rule,window)\n");
#        } else {
#            emit(3, "    if rule not in self.activeRules:\n");
#            emit(3, "        self.activate(rule,window)\n");
#            emit(2, "else:\n");
#            emit(3, "for rule in self.ruleSet$number:\n");
#            emit(3, "    if rule in self.activeRules:\n");
#            emit(3, "        self.deactivate(rule,window)\n");
#        }

sub emit_definition_grammar
{
    my $definition = shift;
    emit(2, "<$definition->{NAME}> = ");
    emit_menu_grammar (@{ $definition->{MENU}->{COMMANDS} });
    emit(0, ";\n");
}

sub emit_command_grammar
{
    my $command = shift;
    inline_a_term_if_nothing_concrete($command);
    my ($first, $last) = find_terms_for_main_rule($command);
    my @terms = @{ $command->{TERMS} };
    my @main_terms = @terms[$first .. $last];
    my $name = $command->{NAME};
    my $name_a = $name . "a";
    my $name_b = $name . "b";
    @main_terms = (create_variable_node($name_a), @main_terms) if $first > 0;
    push (@main_terms, create_variable_node($name_b)) if $last < $#terms;
    emit_rule($command->{NAME}, "", @main_terms);
    emit_rule($name_a, "", @terms[0 .. $first-1]) if $first > 0;
    emit_rule($name_b, "", @terms[$last+1 .. $#terms]) if $last < $#terms;
}

sub emit_rule
{
    my $name = shift;
    my $exported = shift;
    emit(2, "<$name>$exported = ");
    emit_command_terms(@_);
    emit(0, ";\n");
}

sub emit_command_terms
{
    for my $term (@_) {
        if ($term->{OPTIONAL}) {emit(0, "[ ")}
        if ($term->{TYPE} eq "word") {
            my $word = $term->{TEXT};
            if ($word =~ /\'/) {emit(0, '"' . "$word" . '" ')}
            else               {emit(0, "'$word' ")}
        } elsif ($term->{TYPE} eq "variable") {emit(0, "<$term->{TEXT}> ")}
        elsif   ($term->{TYPE} eq "range")    {emit_range_grammar($term)}
        elsif   ($term->{TYPE} eq "menu") {
            emit(0, "(");
            emit_menu_grammar(@{ $term->{COMMANDS}} );
            emit(0, ") ");
        }
        if ($term->{OPTIONAL}) {emit(0, "] ")}
    }
}

sub emit_menu_grammar
{
    emit_command_terms(@{ shift->{TERMS} });
    for my $command (@_) {
        emit(0, "| ");
        emit_command_terms(@{ $command->{TERMS} });
    }
}

sub emit_range_grammar
{
    my $i  = @_[0]->{FROM};
    my $to = @_[0]->{TO};
    emit(0, "($i");
    while (++$i <= $to) {emit(0, " | $i")}
    emit(0, ") ");
}

sub emit_definition_actions
{
    my $definition = shift;
    emit(1, "def get_$definition->{NAME}(self, word):\n");
    emit(2, "actions = Value()\n");
    emit_menu_actions("actions.augment", $definition->{MENU}, 2);
    emit(2, "return actions\n\n");
}

sub emit_function_actions
{
    my $function = shift;
    my $formals = join(', ', ("self", @{ $function->{FORMALS} }));
    emit(1, "def do_$function->{NAME}($formals):\n");
    emit(2, "actions = Value()\n");
    emit_actions("actions.augment", $function->{ACTIONS}, 2);
    emit(2, "return actions\n\n");
}

sub emit_top_command_actions
{
    my $command = shift;
    my @terms = @{ $command->{TERMS} };
    my $nterms = @terms;
    my $function = "gotResults_$command->{NAME}";
    @Variable_terms = get_variable_terms($command); # used in emit_reference

    emit(1, "\# ");
    print_terms (*OUT, @terms);
    emit(0, "\n");
    emit(1, "def $function(self, words, fullResults):\n");
    emit_optional_term_fixup(@terms);
    emit(2, "actions = Value()\n");
    emit_actions("actions.augment", $command->{ACTIONS}, 2);
    emit(2, "actions.perform()\n");
    emit(2, "self.firstWord += $nterms\n");

    # If repeating a command with no <variable> terms (e.g. "Scratch That
    # Scratch That"), our gotResults function will be called only once, with
    # all recognized words. Recurse!
    unless (has_variable_term(@terms)) {
        emit(2, "if len(words) > $nterms: self.$function(words[$nterms:], fullResults)\n");
    }
    emit(0, "\n");
}

sub has_variable_term
{
    for my $term (@_) {
        return 1 if $term->{TYPE} eq "variable";
    }
    return 0;
}

# Our indexing into the "fullResults" array assumes all optional terms were 
# spoken.  So we emit code to insert a dummy entry for each optional word 
# that was not spoken.  (The strategy used could fail in the uncommon case 
# where an optional word is followed by an identical required word.)

sub emit_optional_term_fixup
{
    for my $term (@_) {
        if ($term->{OPTIONAL}) {
            my $index = $term->{NUMBER};
            my $text = $term->{TEXT};
            emit(2, "opt = $index + self.firstWord\n");
            emit(2, "if opt >= len(fullResults) or fullResults[opt][0] != '$text':\n");
            emit(3, "fullResults.insert(opt, 'dummy')\n");
        }
    }   
}

sub emit_actions
{
    my ($collector, $actions, $indent) = @_;
    for my $action (@{$actions}) {
        my $type = $action->{TYPE};
        if ($type eq "reference") {
            emit_reference($collector, $action, $indent);
        } elsif ($type eq "formalref") {
            emit($indent, "$collector($action->{TEXT})\n");
        } elsif ($type eq "word") {
            my $safe_text = make_safe_python_string($action->{TEXT});
            emit($indent, "$collector('$safe_text')\n");
        } elsif ($type eq "call") {
            emit_call($collector, $action, $indent);
        } else {
            die "Unknown action type: '$type'\n";
        }
    }
}

sub get_variable_terms
{
    my $command = shift;
    my @variable_terms;
    for my $term (@{ $command->{TERMS} }) {
        my $type = $term->{TYPE};
        if ($type eq "menu" or $type eq "range" or $type eq "variable") {
            push (@variable_terms, $term);
        }
    }
    return @variable_terms;
}

sub emit_reference
{
    my ($collector, $action, $indent) = @_;
    my $reference_number = $action->{TEXT} - 1;
    my $variable = $Variable_terms[$reference_number];
    my $term_number = $variable->{NUMBER};
    emit($indent, "word = fullResults[$term_number + self.firstWord][0]\n");
    if ($variable->{TYPE} eq "menu") {
        emit_menu_actions($collector, $variable, $indent);
    } elsif ($variable->{TYPE} eq "range") {
        emit($indent, "$collector(word)\n");
    } elsif ($variable->{TYPE} eq "variable") {
        my $function = "self.get_$variable->{TEXT}";
        emit($indent, "$collector($function(word))\n");
    }
}

sub emit_menu_actions
{
    my ($collector, $menu, $indent) = @_;
    if (not menu_has_actions($menu)) {
        emit($indent, "$collector(word)\n");
    } else {
        my @commands = flatten_menu($menu);
        my $if = "if";
        for my $command (@commands) {
            my $text = $command->{TERMS}[0]->{TEXT};
            $text =~ s/'/\\'/g;
            emit($indent, "$if word == '$text':\n");
            if ($command->{ACTIONS}) {
                emit_actions($collector, $command->{ACTIONS}, $indent+1);
            } else {
                emit($indent+1, "$collector('$text')\n");
            }
            $if = "elif";
        }
    }
}

sub emit_call
{
    my ($collector, $call, $indent) = @_;
    my $callType = $call->{CALLTYPE};
    begin_nested_call();
    if    ($callType eq "dragon") {&emit_dragon_call}
    elsif ($callType eq "user"  ) {&emit_user_call}
    elsif ($callType eq "vocola") {
        my $functionName = $call->{TEXT};
        if    ($functionName eq "Eval")   {&emit_call_eval}
        elsif ($functionName eq "Repeat") {&emit_call_repeat}
        else {die "Unknown Vocola function: '$functionName'\n"}
    } else {die "Unknown function call type: '$callType'\n"}
    end_nested_call();
}

sub emit_dragon_call
{
    my ($collector, $call, $indent) = @_;
    my $functionName = $call->{TEXT};
    my $value = get_nested_value_name("call");
    emit($indent, "$value = Call('$functionName')\n");
    for my $argument (@{ $call->{ARGUMENTS} }) {
        emit_argument("$value.addArgument", $argument, $indent);
    }
    emit($indent, "$value.finalize()\n");
    emit($indent, "$collector($value)\n");
}

sub emit_user_call
{
    my ($collector, $call, $indent) = @_;
    my $functionName = $call->{TEXT};
    my $value = get_nested_value_name("usercall");
    emit($indent, "$value = UserCall('self.do_$functionName')\n");
    for my $argument (@{ $call->{ARGUMENTS} }) {
        emit_argument("$value.addArgument", $argument, $indent);
    }
    emit($indent, "$collector(eval($value.getCall()))\n");
}

sub emit_argument
{
    # Note that an argument is a list of actions
    my ($collector, $argument, $indent) = @_;
    if (@{$argument} > 1) {
        my $value = get_nested_value_name("argument");
        emit($indent, "$value = Value()\n");
        emit_actions("$value.augment", $argument, $indent);
        emit($indent, "$collector($value)\n");
    } else {
        emit_actions($collector, $argument, $indent);
    }
}

sub begin_nested_call{ $NestedCallLevel += 1}
sub   end_nested_call{ $NestedCallLevel -= 1}
sub get_nested_value_name
{
    my $root = shift;
    return ($NestedCallLevel == 1) ? $root : "$root$NestedCallLevel";
}

# Eval() takes a single expression argument, which the parser will have
# chopped up into text and variable references. For each reference, generate
# code to compute its value. Then generate code to create a binding in our
# runtime "Evaluator" object using that value and a variable name based on the
# reference number (e.g. "v2"). Then splice the variable back into the
# expression. Finally, generate code to evaluate the expression using the
# bindings!

sub emit_call_eval
{
    my ($collector, $call, $indent) = @_;
    my @arguments = @{ $call->{ARGUMENTS} };
    my $expression = "";
    emit($indent, "evaluator = Evaluator()\n");
    for my $argumentBit (@{$arguments[0]}) {
        my $type = $argumentBit->{TYPE};
        my $text = $argumentBit->{TEXT};
        if ($type eq "reference") {
            $text = "v" . $text;
            emit($indent, "evaluator.setNextVariableName('$text')\n");
            emit_reference("evaluator.setVariable", $argumentBit, $indent);
        } elsif ($type eq "formalref") {
            emit($indent, "evaluator.setNextVariableName('$text')\n");
            emit($indent, "evaluator.setVariable($text)\n");
        }
        $expression .= $text;
    }
    emit($indent, "$collector(evaluator.evaluate('$expression'))\n");
}

sub emit_call_repeat
{
    my ($collector, $call, $indent) = @_;
    my @arguments = @{ $call->{ARGUMENTS} };
    emit($indent, "limit = Value()\n");
    emit_actions("limit.augment", $arguments[0], $indent);
    emit($indent, "for i in range(int(str(limit))):\n");
    emit_actions($collector, $arguments[1], $indent+1);
}

# ---------------------------------------------------------------------------
# Utilities for transforming command terms into NatLink rules 
#
# For each Vocola command, we define a NatLink rule and an associated
# "gotResults" function. When the command is spoken, we want the gotResults
# function to be called exactly once. But life is difficult -- NatLink calls a
# gotResults function once for each contiguous sequence of spoken words
# specifically present in the associated rule. There are two problems:
#
# 1) If a rule contains only references to other rules, it won't be called 
#
# We solve this by "inlining" variables (replacing a variable term with the
# variable's definition) until the command is "concrete" (all branches contain
# a non-optional word).
#
# 2) If a rule is "split" (e.g. "Kill <n> Words") it will be called twice
#
# We solve this by generating two rules, e.g.
#    <1> exported = 'Kill' <n> <1a> ;
#    <1a> = 'Words' ;

sub find_terms_for_main_rule
{
    # Create a "variability profile" summarizing whether each term is
    # concrete (c), variable (v), or optional (o).  For example, the profile of
    # "[One] Word <direction>" would be "ocv". (Menus are assumed concrete.)

    $_ = "";
    for my $term (@{ shift->{TERMS} }) {
        $_ .= ($term->{TYPE} eq "variable") ? "v" :
              ($term->{OPTIONAL})           ? "o" : "c";
    }

    # Identify terms to use for main rule.
    # We might not start with the first term. For example:
    #     [Move] <n> Left  -->  "Left" is the first term to use
    # We might not end with the last term. For example:
    #     Kill <n> Words   -->  "Kill" is the last term to use
    # And in this combined example, our terms would be "Left and Kill"
    #     [Move] <n> Left and Kill <n> Words

    my $first = /^(v*o+v[ov]*c)/        ? length($1)-1 : 0;
    my $last  = /^([ov]*c[co]*)v+[co]+/ ? length($1)-1 : length($_)-1;
    return ($first, $last);
}

sub inline_a_term_if_nothing_concrete
{
    my $command = shift;
    while (!command_has_a_concrete_term($command)) {
        inline_a_term($command);
    }
}

sub command_has_a_concrete_term
{
    my $command = shift;
    for my $term (@{ $command->{TERMS} }) {
        return 1 if term_is_concrete($term);
    }
    return 0;
}

sub term_is_concrete
{
    my $term = shift;
    my $type = $term->{TYPE};
    if    ($type eq "menu")     {return 1}
    elsif ($type eq "variable") {return 0}
    else                        {return not $term->{OPTIONAL}}
}

sub inline_a_term
{
    my $terms = shift->{TERMS};

    # Find the array index of the first non-optional term
    my $index = 0;
    $index++ while $index < @{$terms} and $terms->[$index]->{OPTIONAL};

    my $type = $terms->[$index]->{TYPE};
    my $number = $terms->[$index]->{NUMBER};
    if ($type eq "variable") {
        my $variable_name = $terms->[$index]->{TEXT};
        #print "inlining variable $variable_name\n";
        my $definition = $Definitions{$variable_name};
        $terms->[$index] = $definition->{MENU};
        $terms->[$index]->{NUMBER} = $number;
    } elsif ($type eq "menu") {
        for my $command (@{ $terms->[$index]->{COMMANDS} }) {
            inline_a_term($command);
        }
    } else {die "Internal error inlining term of type '$type'\n"}
}

# ---------------------------------------------------------------------------
# Utilities used by "emit" methods

sub emit
{
    my ($indent, $string) = @_;
    print OUT ' ' x (4 * $indent), $string;
}

sub menu_has_actions
{
    for my $command (@{ shift->{COMMANDS} }) {
        return 1 if $command->{ACTIONS};
        for $term (@{ $command->{TERMS} }) {
            return 1 if $term->{TYPE} eq "menu" and menu_has_actions($term);
        }
    }
    return;
}

# To emit actions for a menu, build a flat list of (canonicalized) commands:
#     - recursively extract commands from nested menus
#     - distribute actions, i.e. (day|days)=d --> (day=d|days=d)
# Note that error checking happened during parsing, in verify_referenced_menu

sub flatten_menu
{
    my ($menu, $actions_to_distribute) = @_;
    my (@new_commands, $new_actions);
    for my $command (@{ $menu->{COMMANDS} }) {
        if ($command->{ACTIONS}) {$new_actions = $command->{ACTIONS}}
        else                     {$new_actions = $actions_to_distribute}
        my @terms = @{ $command->{TERMS} };
        my $type = $terms[0]->{TYPE};
        if ($type eq "word") {
            $command->{ACTIONS} = $new_actions if $new_actions;
            push (@new_commands, $command);
        } elsif ($type eq "menu") {
            my @commands = flatten_menu ($terms[0], $new_actions);
            push (@new_commands, @commands);
        } 
    }
    return @new_commands;
}

sub make_safe_python_string
{
    $_[0] =~ s/'/\\'/g;
    return $_[0];
}

# ---------------------------------------------------------------------------
# Pieces of the output Python file

sub emit_file_header
{
    $now = localtime;
    print OUT "\# NatLink macro definitions for NaturallySpeaking\n"; 
    print OUT "\# Generated by vcl2py $VocolaVersion, $now\n";
    print OUT <<MARK;

import natlink
from natlinkutils import *
from VocolaUtils import *

class ThisGrammar(GrammarBase):

    gramSpec = """
MARK
}

sub emit_file_middle
{
    print OUT <<MARK;
    """
    
    def initialize(self):
        self.load(self.gramSpec)
        self.currentModule = ("","",0)
MARK
}

sub emit_file_trailer
{
    print OUT <<MARK;
thisGrammar = ThisGrammar()
thisGrammar.initialize()

def unload():
    global thisGrammar
    if thisGrammar: thisGrammar.unload()
    thisGrammar = None
MARK
}

# ---------------------------------------------------------------------------
# Okay, let's run!

main();