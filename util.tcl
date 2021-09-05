if {[namespace exists util]} {
    return
}
package require Tcl 8.6
namespace path {::tcl::mathop ::tcl::mathfunc}

namespace eval util {
	source [file join [info library] init.tcl]
	namespace path {::tcl::mathop ::tcl::mathfunc}
	namespace export *

                               ##################
                               # Misc utilities #
                               ##################

	proc procname {} {
		dict get [info frame -1] proc
	}

	# A nice apply wrapper that uses the caller's namespace if not specified
	#
	# Example:
	#     % set l [lambda args {puts $args}]; puts $l
	#     apply {args {puts $args} ::}
	#     % {*}$l c "d e"
	#     c d e
	proc lambda {params body {ns ""}} {
		list apply [list $params $body [? {$ns ne ""} {$ns} {[uplevel 1 namespace current]}]]
	}

	# Partial application of lambdas
	proc papply {lambda args} {
		concat $lambda $args
	}

	# Named argument version of proc; $args contains the merged optional/provided argument dict
	# and dict::assign is called on this dict before evaluating the body
	#
	# Example:
	#     % naproc test {arg1 arg2} {arg3 1 arg4 {hello world}} {
	#           puts [list $arg1 $arg2 $arg3 $arg4]
	#       }
	#     % test arg1 foo arg2 bar
	#     foo bar 1 {hello world}
	#     % test arg1 foo arg2 bar arg3 zzz
	#     foo bar zzz {hello world}
	proc naproc {name mandatory_args optional_args body} {
		tailcall proc $name args [template {
			if {[llength $args] % 2 != 0} {
				error "[util::procname]: args isn't a dictionary"
			}
			if {[llength @mandatory_args@] != 0} {
				foreach marg @mandatory_args@ {
					dict set margset $marg {}
				}
				dict for {key val} $args {
					if {[::tcl::mathop::in $key @mandatory_args@]} {
						dict unset margset $key
						if {[dict size $margset] == 0} {
							break
						}
					} elseif {![dict exists @optional_args@ $key]} {
						error "[util::procname]: unknown argument `$key`"
					}
				}
				if {[dict size $margset] != 0} {
					set arglist [util::pretty_list [dict keys $margset]]
					error [string cat "[util::procname]: mandatory "           \
							   "argument[util::? {[llength $arglist] > 1} s] " \
							   [util::pretty_list [dict keys $margset]]        \
							   " missing"]
				}
			}
			set args [dict merge @optional_args@ $args]
			dict assign $args
		}]\n$body
	}

	# Detect if a channel is a tty
	proc ::tcl::chan::isatty {chan} {
		::tcl::mathop::! [catch {chan configure $chan -mode}]
	}

	namespace ensemble configure chan -map \
		[linsert [namespace ensemble configure chan -map] end \
			 isatty ::tcl::chan::isatty]

	# Identity
	proc id {x} {
		string cat $x
	}

	proc decr {_x {decrement 1}} {
		upvar $_x x
		incr x -$decrement
	}

	proc until {test body} {
		tailcall while !($test) $body
	}

	# Random integer in range [0, max[
	proc irand {max} {
		int [* [rand] $max]
	}

	proc do {body keyword test} {
		if {$keyword eq "while"} {
			set test "!($test)"
		} elseif {$keyword ne "until"} {
			return -code error "unknown keyword `$keyword`: must be until or while"
		}
		set cond [list expr $test]
		while 1 {
			uplevel 1 $body
			if {[uplevel 1 $cond]} {
				break
			}
		}
		return
	}

	# Allow to call variable with multiple names
	proc variables {args} {
		foreach name $args {
			uplevel 1 variable $name
		}
	}

	# Ternary; properly quote variables/command substs to avoid surprises
	proc ? {test a {b {}}} {
		tailcall if $test [list subst $a] [list subst $b]
	}

	# Like shift(1) but assign the shift values to args
	# Returns 1 if argv was at least as large as args, 0 otherwise
	proc shift {args} {
		global argc

		set argnum [llength $args]
		if {$argnum > $argc} {
			return 0
		}
		uplevel 1 "global argv; set argv \[lassign \$argv $args\]"
		decr argc $argnum
		return 1
	}

	# Graceful death, don't unwind like error
	proc die {msg {code 1}} {
		puts stderr $msg
		exit $code
	}

	# Eval $body in namespace $ns every $ms milliseconds or cancel an existing every
	proc every {ms body {ns ""}} {
		variable every

		if {$ns eq ""} {
			set ns [uplevel 1 namespace current]
		}

		if {$ms eq "cancel"} {
			after cancel [dict get $every $ns $body]
			return
		}
		namespace inscope $ns $body
		dict set every $ns $body [after $ms [namespace code [list every $ms $body $ns]]]
	}

	# Open a FIFO (named pipe) for IPC purposes at $path and add $body as readable event
	# handler evaluted in the caller's namespace with $chan set to the returned channel
	proc open_ipc_fifo {path body} {
		variable ipc_fifo_dummy_writer

		catch {exec mkfifo $path}
		set fifo [open $path {RDONLY NONBLOCK}]
		dict set ipc_fifo_dummy_writer $fifo [open $path WRONLY]
		chan event $fifo readable \
			[papply [lambda chan $body [uplevel 1 namespace current]] $fifo]
		return $fifo
	}

	proc close_ipc_fifo {chan} {
		variable ipc_fifo_dummy_writer

		close $chan
		close [dict get $ipc_fifo_dummy_writer $chan]
	}

                         #############################
                         # String and text utilities #
                         #############################

	# Opposite of append
	proc prepend {_var args} {
		upvar $_var var
		set var [string cat [? {[info exists var]} {$var}] {*}$args]
	}

	# Produces a string of the form `elem1`, `elem2`, ... and `elemEnd`
	proc pretty_list {list} {
		if {[llength $list] == 0} {
			return
		}
		set res `[lindex $list 0]`
		foreach elem [lrange $list 1 end-1] {
			append res ", `$elem`"
		}
		if {[llength $list] > 1} {
			append res " and `[lindex $list end]`"
		}
		return $res
	}

	# Selectively replace strings of the form @varname@ in the last argument by either
	# the variables available in the caller (minus global tclvars) or the remaining arguments
	# as a {varname value...} list; the substituted value is always quoted
	#
	# Example:
	#     % set var1 foobar
	#     % eval [template var2 {hello world} {puts "@var1@ [join @var2@ ", "]"}]
	#     foobar hello, world
	proc template {args} {
		foreach var [uplevel 1 info vars] {
			if {$var ni {
				auto_path env errorCode errorInfo tcl_library tcl_patchLevel tcl_pkgPath
				tcl_platform tcl_precision tcl_rcFileName tcl_traceCompile tcl_traceExec
				tcl_wordchars tcl_nonwordchars tcl_version argc argv argv0 tcl_interactive
			} && [uplevel 1 [list info exists $var]] && ![uplevel 1 [list array exists $var]]} {
				lappend map [list @$var@] [list [uplevel 1 [list set $var]]]
			}
		}
		foreach {var val} [lrange $args 0 end-1] {
			lappend map [list @$var@] [list $val]
		}
		string map $map [lindex $args end]
	}

	# Like textutil::adjust followed by textutil::indent with the following
	# differences :
	# * Add terminal markup and handles it properly (don't count the SGR sequences in text width).
	# * Use textutil::wcswidth is text isn't ASCII.
	#
	# args is a dict with the following optional key/values (otherwise, defaults are used):
	# * markup  Dict with the keys: {bold dim underline blink reverse strike}
	#           and the markup string delimiter, or list of two strings for
	#           different start/end delimiters as value.
	# * indent  How many spaces of indentation.
	# * width   Desired printing width.
	# * dumb    Strip markup without translating it (mostly for when stdout
	#           isn't a tty).
	#
	# ToDo: add color?
	proc format_paragraph {text args} {
		variable ecma48_sgr

		set opts [dict merge \
					  [dict create \
						   markup {
							   bold      **
							   dim       {}
							   underline __
							   blink     {}
							   reverse   !!
							   strike    --} \
						   indent 0 \
						   width 80 \
						   dumb 0] \
					  $args]
		dict assign $opts
		if {![string is ascii text] && ![catch {package require textutil}] &&
			![catch {package present textutil::wcswidth}]} {
			interp alias {} textwidth {} ::textutil::wcswidth
		} else {
			interp alias {} textwidth {} ::tcl::string::length
		}

		if {!$dumb} {
			# Escape subst sensitive characters
			set map {[ \\[ $ \\$}
			# Create a map to modify state and emit corresponsing sequence for each symbol
			set state [dict map {key val} $markup {id 0}]
			dict for {attr sym} $markup {
				switch [llength $sym] {
					0 {}
					1 {
						lappend map $sym
						lappend map "\[if {\[dict get \$state $attr\]} {
										   dict set state $attr 0
										   dict get \$ecma48_sgr $attr off
									   } else {
										   dict set state $attr 1
										   dict get \$ecma48_sgr $attr on
									   }\]"
					}
					2 {
						lappend map [lindex $sym 0]
						lappend map "\[dict set state $attr 1
									   dict get \$ecma48_sgr $attr on\]"
						lappend map [lindex $sym 1]
						lappend map "\[dict set state $attr 0
									   dict get \$ecma48_sgr $attr off\]"
					}
					default {error "$sym: invalid markup item"}
				}
			}
			set text [subst [string map $map $text]]
			dict for {key val} $state {
				if {$val == 1} {
					error "Unclosed $key attr sequence"
				}
			}
		} else {
			dict for {attr sym} $markup {
				switch [llength $sym] {
					0 {}
					1 {lappend map $sym {}}
					2 {lappend map [lindex $sym 0] {} [lindex $sym 1] {}}
					default {error "$sym: invalid markup item"}
				}
			}
			set text [string map $map $text]
		}

		set ret {}
		set line {}
		set linelen $width; # Force line break case in first loop iter
		foreach word [regexp -all -inline {[^\t\n ]+} $text] {
			set wordlen [textwidth [regsub -all {\x1b\[\d{1,2}m} $word {}]]
			if {$linelen + $wordlen > $width} {
				if {$line ne ""} { # Not first line
					append ret $line\n
				}
				set line [string repeat " " $indent]$word
				set linelen [+ $indent $wordlen]
			} else {
				append line " $word"
				incr linelen [+ $wordlen 1]
			}
		}
		append ret $line
		interp alias {} textwidth {}
		return $ret
	}

	# All-in-one CLI creation. Sets a pretty usage proc and parses argv
	# according to flag/parametric options of the form "-opt ?param?".
	#
	# optspec      Dict with:
	#                  key  Option name without starting dash.
	#                  val  {"flag" ?optdescr_par ...?}
	#                           or
	#                       {"param" default_value ?val_name optdescr_par ...?}
	# name         Progam name.
	# short_descr  Description in a few words.
	# synargslist  Synopsis arguments lists (for multiple synopsis). Must use
	#              the traditional [] and ... notation for optional and
	#              multiple arguments to get automatic markup.
	# long_descr   Optional long description as a list of (possibly indented) paragraphs.
	#
	# Creates a usage proc in this namespace with the following synopsis:
	#     usage chan ?exit_code?
	# which prints the usage message to $chan and, if exit_code is specified, calls exit $exit_code
	#
	# ::argv and ::argc are modified to only leave the arguments that aren't options.
	# Returns the parsed options in the same form as optspec but with values filled with
	# the parsed value or specified default; flag value is 1 if found, 0 otherwise.
	proc autocli {optspec name short_descr synargslist {long_descr ""}} {
		global argv argc

		set body [join [list [list set optspec $optspec] \
					  [list set name $name] \
					  [list set short_descr $short_descr] \
					  [list set synargslist $synargslist] \
					  [list set long_descr $long_descr]] \
				 \n]
		append body {
			global tcl_platform

			set tabw 4
			set printw [min [tput cols] 80]
			set opts [dict create \
						  width $printw \
						  dumb [| [ne $tcl_platform(platform) unix] [! [chan isatty $chan]]] \
						 ]
			puts $chan [format_paragraph **NAME** {*}$opts]
			puts $chan [format_paragraph "$name - $short_descr" indent $tabw {*}$opts]\n
			puts $chan [format_paragraph **SYNOPSIS** {*}$opts]
			set synindent [+ [string length $name] $tabw 1]
			set synopts {}
			foreach synargs $synargslist {
				puts -nonewline $chan "[format_paragraph "**$name**" indent $tabw {*}$opts] "
				if {$optspec ne ""} {
					set synargs "\[__OPTION__\]... $synargs"
				}
				regsub -all {[A-Z0-9_]+}  $synargs {__&__} synargs
				regsub -all {[][]} $synargs {**&**} synargs
				puts $chan [string trimleft [format_paragraph $synargs indent $synindent {*}$opts]]
			}
			puts $chan {}
			if {$long_descr ne ""} {
				puts $chan [format_paragraph **DESCRIPTION** {*}$opts]
				foreach par $long_descr {
					if {$par eq ""} {
						puts $chan {}
						continue
					}
					set indent [+ [string length [regexp -inline {^ +} $par]] $tabw]
					puts $chan [format_paragraph $par indent $indent {*}$opts]
				}
			}
			puts $chan {}
			puts $chan [format_paragraph **OPTIONS** {*}$opts]
			dict set optspec help {flag "Print this help message and exit."}
			dict for {key val} $optspec {
				if {[lindex $val 0] eq "flag"} {
					puts $chan [format_paragraph "**-$key**" indent $tabw {*}$opts]
					foreach par [lrange $val 1 end] {
						puts $chan [format_paragraph $par indent [* $tabw 2] {*}$opts]
					}
				} else {
					set par "**-$key**[? {[llength $val] >= 4} { __[lindex $val 2]__}]"
					puts $chan [format_paragraph $par indent $tabw {*}$opts]
					foreach par [lrange $val 3 end] {
						puts $chan [format_paragraph $par indent [* $tabw 2] {*}$opts]
					}
					if {[lindex $val 1] ne ""} {
						puts $chan [format_paragraph "Defaults to `[lindex $val 1]`." \
										indent [* $tabw 2] {*}$opts]
					}
				}
				puts $chan {}
			}
			if {$exit_code ne ""} {
				exit $exit_code
			}
		}
		proc usage {chan {exit_code ""}} $body

		set result [dict create]
		# Validate and fill defaut values for result
		dict for {key val} $optspec {
			if {![string is list $val]} {
				error "$val: invalid optspec value for key $key; not a valid list"
			}
			set type [lindex $val 0]
			if {$type eq "flag"} {
				dict set result $key 0
			} elseif {$type eq "param"} {
				set vallen [llength $val]
				if {$vallen < 2} {
					error "$val: invalid optspec value for key $key; missing default value"
				}
				set default [lindex $val 1]
				dict set result $key $default
			} else {
				error "$val: invalid optspec value for key $key; invalid opt type"
			}
		}

		while {[shift arg]} {
			switch -glob -nocase -- $arg {
				-- {break}
				-help {usage stdout 0}
				-?* {
					set key [string range $arg 1 end]
					if {[dict get? $optspec val $key]} {
						set val [lindex $val 0]
						switch $val {
							flag {dict set result $key 1}
							param {
								if {![shift param]} {

									puts stderr "option $arg requires a parameter\n"
									usage stderr 1
								}
								dict set result $key $param
							}
						}
					} else {
						puts stderr "$arg: unknown option\n"
						usage stderr 1
					}
				}
				default {
					incr argc
					lprepend argv $arg
					break
				}
			}
		}
		return $result
	}

	# Split a string into block of size chars (last block can be of inferior size)
	proc block_split {str size} {regexp -inline -all ".{1,$size}" $str}

	# AWK like text parsing; only the `parse {data script args}` proc is to be called directly
	# $data is the text to parse, $script is a list of condition/action pairs (rules) and $args is a
	# dict containing options with keys FS (field separator) and RS (record separator)
	#
	# The process is as follow:
	# 1| If there is a rule with its condition equal to BEGIN, execute it
	# 2| Foreach record [split $data $RS] (record actually stored in variable named 0)
	# 3|     Split $0 into fields (list F), populate NF (field number) and read-only
	#            aliases 1..NF (so that [lindex $F 0] == $1 and so on)
	# 4|     Incr NR (starts at 1)
	# 5|     Foreach {cond action} $script
	# 6|         if {$cond} eval $action
	# 7| If there is a rule with its condition equal to END, execute it
	# 8| Return the value of variable RET
	#
	# Some local procs are available for convenience during action evaluation (6):
	# * ~ regexp ?string?
	#       regexp $exp $string (or $0 if no $string is specified) wrapper
	# * exit ?mode?:
	#       if mode is "action", exit the current action (continue loop 5)
	#       if mode is "record", stop processing of current record and proceed to the next
	#           (continue loop 2, equivalent to AWK's next statement)
	#       if mode is "end", stop processing and process END rule (goto 7)
	#       if no mode is given, stop processing (goto 8)
	#
	# ToDo: handle empty $data?
	# ToDo: don't split $data, use string first and range to extract records
	#       to allow for RS changes and getline proc
	interp alias {} ::util::parse {} ::util::parse::parse
	namespace eval parse {
		namespace import ::util::*
		namespace path {::tcl::mathop ::tcl::mathfunc}

		variables F FS RS NF NR

		proc exit {{mode ""}} {
			switch $mode {
				action  {return -code 5}
				record  {return -code 6}
				end     {return -code 7}
				""      {return -code 8}
				default {error "$mode: unknown mode, must be `action`, `record` or `end`"}
			}
		}

		proc ~ {args} {
			switch [llength $args] {
				1 {upvar 1 0 0; regexp {*}$args $0}
				2 {regexp {*}$args}
				0 -
				default {error "=~ regexp ?string?"}
			}
		}

		proc fieldsplit {args} {
			variables F FS NF NR
			upvar 0 0

			set F [switch -glob $FS {
				" "		{set 0}
				?		{split $0 $FS}
				default {
					package require textutil::split
					::textutil::split::splitx $0 $FS
				}
			}]
			if {$NR} {
				uplevel 1 unset [util::iota $NF 1]
			}
			set NF [llength $F]
			uplevel 1 [list lassign $F] [util::iota $NF 1]
		}

		proc parse {data script args} {
			variables F FS RS NF NR
			dict assign [dict merge [dict create FS " " RS \n] $args]
			set RET {}
			set NR 0

			if {[set i [lsearch -exact $script BEGIN]] != -1} {
				set begaction [lindex $script [+ $i 1]]
				set script [lreplace $script $i $i+1]
			}
			if {[set i [lsearch -exact $script END]] != -1} {
				set endaction [lindex $script [+ $i 1]]
				set script [lreplace $script $i $i+1]
			}

			set exit 0
			if {[info exists begaction]} {
				try $begaction \
					on 5 {} {} \
					on 6 {} {error "`exit record` has no meaning in a BEGIN action"} \
					on 7 {} {set exit 1} \
					on 8 {} {set exit 2}
			}
			if {$exit == 0} {
				trace add variable FS write fieldsplit
				trace add variable 0  write fieldsplit
				try {
					foreach 0 [split $data $RS] {
						incr NR
						foreach {pattern action} $script {
							if $pattern {
								try $action \
									on 5 {} {} \
									on 6 {} {break} \
									on 7 {} {set exit 1; break} \
									on 8 {} {set exit 2; break}
							}
						}
						if {$exit != 0} {
							break
						}
					}
				} finally {
					trace remove variable FS write fieldsplit
					trace remove variable 0  write fieldsplit
				}
			}
			if {$exit < 2 && [info exists endaction]} {
				try $endaction \
					on 5 {} {} \
					on 6 {} {error "`exit record` has no meaning in an END action"} \
					on 7 {} {error "`exit end` has no meaning in an END action"} \
					on 8 {} {}
			}
			return $RET
		}
	}


                          ###########################
                          # Path and file utilities #
                          ###########################

	# Die if executable `name` isn't available
	proc exec_require {name} {
		if {[auto_execok $name] eq ""} {
			die "$name: executable not found"
		}
	}

	# Useful open/read/close wrapper
	proc read_wrap {path args} {
		set chan [open $path {*}$args]
		set result [read $chan]
		close $chan
		return $result
	}

	# Useful open/puts/close wrapper
	proc write_wrap {path data args} {
		set chan [open $path {*}[? {$args eq ""} w {$args}]]
		puts $chan $data
		close $chan
	}

	# Remove some forbidden/annoying characters from str when used as POSIX
	# path component
	proc path_sanitize {str {repl _}} {
		regsub -all {[\x0-\x1f/]} $str $repl
	}

	# Explicit
	proc is_dir_empty {path} {
		if {![file isdirectory $path]} {
			error "$path: not a directory"
		}
		== [llength [glob -nocomplain -tails -directory $path * .*]] 2
	}

	# glob wrapper sorting by mtime
	proc glob_mtime {args} {
		lmap x [lsort -integer -index 0 \
					[lmap x [glob {*}$args] {list [file mtime $x] $x}]] \
			{lindex $x 1}
	}

	# Rename all the files in dir according to their mtime
	proc rename_mtime {{dir .}} {
		set paths [glob_mtime -directory $dir *]
		set fmt %0[string length [llength $paths]]u
		foreach path $paths {
			incr count
			set target [file join $dir [format $fmt $count][file extension $path]]
			file rename -force -- $path $target
		}
	}

                               ##################
                               # List utilities #
                               ##################

	# Like lmap, but expr is used as an if argument to filter values
	proc lfilter {var list test} {
		tailcall lmap $var $list [list if $test [list set $var] else continue]
	}

	# Traditional FP foldl/reduce
	# Examples:
	#     % lreduce {1 2 3 4} 0  {acc elem}  {+ $acc $elem}
	#     10
	#     % lreduce {1 2 3 4} 0  {acc e1 e2} {+ $acc [* $e1 $e2]}
	#     14
	#     % lreduce {1 2 3 4} "" {acc elem}  {string cat $acc $elem}
	#     1234
	proc lreduce {list init argvars script} {
		set elem_vars [lassign $argvars acc_var]
		upvar 1 $acc_var $acc_var
		foreach elem_var $elem_vars {
			upvar 1 $elem_var $elem_var
		}
		set $acc_var $init
		foreach $elem_vars $list {
			set $acc_var [uplevel 1 $script]
		}
		set $acc_var
	}

	# Traditional FP foldl/reduce (inplace)
	# Examples:
	#     % lreduceip {1 2 3 4} 0  {acc elem}  {incr acc $elem}
	#     10
	#     % lreduceip {1 2 3 4} 0  {acc e1 e2} {incr acc [* $e1 $e2]}
	#     14
	#     % lreduceip {1 2 3 4} "" {acc elem}  {append acc $elem}
	#     1234
	proc lreduceip {list init argvars script} {
		set elem_vars [lassign $argvars acc_var]
		upvar 1 $acc_var $acc_var
		foreach elem_var $elem_vars {
			upvar 1 $elem_var $elem_var
		}
		set $acc_var $init
		foreach $elem_vars $list {
			uplevel 1 $script
		}
		set $acc_var
	}

	# Opposite of lappend
	proc lprepend {_list args} {
		upvar $_list list
		lappend list ;# Used as a an "is a list" check and to do var creation
		set list [linsert $list [set list 0] {*}$args]
	}

	# Create a sequence of num elements, starting from start and with step
	# as difference between an element and its predecessor
	proc iota {num {start 0} {step 1}} {
		set res {}
		set end [+ $start [* $num $step]]
		for {set n $start} {$n != $end} {incr n $step} {
			lappend res $n
		}
		return $res
	}

	# incr on a list item
	proc lincr {_list index {increment 1}} {
		upvar $_list list
		lset list $index [+ [lindex $list $index] $increment]
	}

	# lassign _list and set it to the result immediately; returns nothing
	proc lshift {_list args} {
		uplevel 1 "set [list $_list] \[lassign \$[list $_list] $args\]"
	}

	# Append suffix to all the elements of list and return the resulting list
	proc lsuffix {list suffix} {
		lmap x $list {id $x$suffix}
	}

	# Prepend prefix to all the elements of list and return the resulting list
	proc lprefix {list prefix} {
		lmap x $list {id $prefix$x}
	}

	# Fast inplace lreplace
	proc lreplaceip {_list args} {
		upvar 1 $_list list
		set list [lreplace $list[set list {}] {*}$args]
	}

                               ##################
                               # Dict utilities #
                               ##################

	# Check if str is a valid dict
	proc is_dict {str} {
		expr {[string is list $str] && [llength $str] % 2 == 0}
	}

	# Conditional dict get, sets _var only if the key is to be found in dict.
	# Returns 1 if it was found, 0 otherwise.
	proc ::tcl::dict::get? {dict _var args} {
		upvar $_var var
		if {[exists $dict {*}$args]} {
			::set var [get $dict {*}$args]
			return 1
		}
		return 0
	}

	# Assign the dict values to key-named variables (with s/[ -]/_/g applied to
	# them).
	proc ::tcl::dict::assign {dict} {
		tailcall lassign [values $dict] {*}[lmap s [keys $dict] {string map {- _ " " _} $s}]
	}

	# Join a dict to produce a string of the form
	# string cat $key_1 $inner $val_1 $outer $key_2 $inner $val_2 ... $key_end $inner $val_end
	proc ::tcl::dict::join {dict {inner " "} {outer \n}} {
		dict for {key val} $dict {
			::append acc $outer$key$inner$val
		}
		string range $acc [string length $inner] end
	}


	# dict lappend with support for nested dictionaries while lappending
	# only one element
	proc ::tcl::dict::lappendn {_dict args} {
		upvar 1 $_dict d
		::set keys [::lrange $args 0 end-1]
		::set arg [::lindex $args end]
		try {
			set d {*}$keys [list {*}[get $d {*}$keys] $arg]
		} on error {} {
			set d {*}$keys [list $arg]
		}
	}

	# dict append with support for nested dictionaries while appending
	# only one element
	proc ::tcl::dict::appendn {_dict args} {
		upvar 1 $_dict d
		::set keys [::lrange $args 0 end-1]
		::set arg [::lindex $args end]
		try {
			set d {*}$keys [string cat [get $d {*}$keys] $arg]
		} on error {} {
			set d {*}$keys $arg
		}
	}

	# dict incr with support for nested dictionaries that only incr by 1
	proc ::tcl::dict::incrn {_dict args} {
		upvar 1 $_dict d
		try {
			set d {*}$args [::tcl::mathop::+ [get $d {*}$args] 1]
		} on error {} {
			set d {*}$args 1
		}
	}

	# Like dict::incrn but with a specified increment instead of 1
	proc ::tcl::dict::add {_dict args} {
		upvar 1 $_dict d
		::set keys [::lrange $args 0 end-1]
		::set arg [::lindex $args end]
		try {
			set d {*}$keys [::tcl::mathop::+ [get $d {*}$keys] $arg]
		} on error {} {
			set d {*}$keys $arg
		}
	}

	namespace ensemble configure dict -map \
		[linsert [namespace ensemble configure dict -map] end \
			 get?     ::tcl::dict::get? \
			 assign   ::tcl::dict::assign \
			 appendn  ::tcl::dict::appendn \
			 incrn    ::tcl::dict::incrn \
			 join     ::tcl::dict::join \
			 lappendn ::tcl::dict::lappendn \
			 add      ::tcl::dict::add]

                              ####################
                              # Binary utilities #
                              ####################

	# Print byte range as space separated hex values
	proc hex_bytes {bytes {offset 0} {count *}} {
		binary scan $bytes @${offset}cu$count hex
		join [lmap x $hex {format %02x $x}]
	}

	# Compute and store in _cursor the new cursor position according to fmt
	# end is the binary string length (for counts '*')
	proc ::tcl::binary::update_cursor {fmt _cursor end} {
		namespace path ::tcl::mathop
		upvar $_cursor cursor

		set atom_re {[aAbBHhcsStiInwWmfrRdqQxX@]u?(?:[0-9]+)?(?= *)}
		foreach atom [regexp -all -inline $atom_re $fmt] {
			set 1 [string index $atom 0]
			set 2 [string index $atom 1]
			switch [string length $atom] {
				1 {set count 1}
				2 {set count [util::? {$2 eq "u"} 1 $2]}
				default {set count [string range $atom [util::? {$2 eq "u"} 2 1] end]}
			}
			if {$count eq "*"} {
				set cursor $end
				continue
			}
			switch $1 {
				a -
				A -
				h -
				H -
				c -
				C {incr cursor $count}
				s -
				S -
				t {incr cursor [* $count 2]}
				i -
				I -
				n -
				f -
				r -
				R {incr cursor [* $count 4]}
				w -
				W -
				m -
				d -
				q -
				Q {incr cursor [* $count 8]}
				b -
				B {incr cursor [/ [+ $count 7] 8]}
				x {incr cursor $count}
				X {incr cursor -$count}
				@ {set cursor $count}
			}
		}
	}

	if {[info commands ::tcl::binary::_scan] eq ""} {
		rename ::tcl::binary::scan ::tcl::binary::_scan
	}

	# New binary scan with the following features:
	# * if fmt starts with ">", read the last argument as an offset variable and
	#   use it as starting cursor value
	# * if fmt ends with ">", read the last argument as an offset variable and
	#   write the last cursor position in it
	proc ::tcl::binary::scan {str fmt args} {
		set rd [string equal [string index $fmt 0] >]
		set wr [string equal [string index $fmt end] >]
		if {$rd || $wr} {
			upvar [lindex $args end] cursor
			util::lreplaceip args end end
		}
		if {$rd} {
			set fmt @$cursor[string range $fmt 1 end]
		}
		if {$wr} {
			set fmt [string range $fmt 0 end-1]
			update_cursor $fmt cursor [string length $str]
		}
		_scan $str $fmt {*}$args
	}

                             ######################
                             # Terminal utilities #
                             ######################

	# Contains the code for terminal emulator relevant ECMA-48 SGR with the bright color extension
	# cf https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_(Select_Graphic_Rendition)_parameters
	variable ecma48_sgr [dict create \
							 reset     \x1b\[0m \
							 bold      [dict create on \x1b\[1m off \x1b\[22m] \
							 dim       [dict create on \x1b\[2m off \x1b\[22m] \
							 italic    [dict create on \x1b\[3m off \x1b\[23m] \
							 underline [dict create on \x1b\[4m off \x1b\[24m] \
							 blink     [dict create on \x1b\[5m off \x1b\[25m] \
							 reverse   [dict create on \x1b\[7m off \x1b\[27m] \
							 invisible [dict create on \x1b\[8m off \x1b\[28m] \
							 strike    [dict create on \x1b\[9m off \x1b\[29m] \
							 fgcolor   [dict create \
											black          \x1b\[30m \
											red            \x1b\[31m \
											green          \x1b\[32m \
											yellow         \x1b\[33m \
											blue           \x1b\[34m \
											magenta        \x1b\[35m \
											cyan           \x1b\[36m \
											white          \x1b\[37m \
											gray           \x1b\[90m \
											bright_black   \x1b\[90m \
											bright_red     \x1b\[91m \
											bright_green   \x1b\[92m \
											bright_yellow  \x1b\[93m \
											bright_blue    \x1b\[94m \
											bright_magenta \x1b\[95m \
											bright_cyan    \x1b\[96m \
											bright_white   \x1b\[97m \
										   ] \
							 bgcolor   [dict create \
											black          \x1b\[40m \
											red            \x1b\[41m \
											green          \x1b\[42m \
											yellow         \x1b\[43m \
											blue           \x1b\[44m \
											magenta        \x1b\[45m \
											cyan           \x1b\[46m \
											white          \x1b\[47m \
											gray           \x1b\[100m \
											bright_black   \x1b\[100m \
											bright_red     \x1b\[101m \
											bright_green   \x1b\[102m \
											bright_yellow  \x1b\[103m \
											bright_blue    \x1b\[104m \
											bright_magenta \x1b\[105m \
											bright_cyan    \x1b\[106m \
											bright_white   \x1b\[107m \
										   ] \
							]

	variable tput_cache [dict create]

	# tput wrapper with memoization
	proc tput {args} {
		variable tput_cache

		if {$args in {lines cols}} {
			set res [::util::read_wrap "|tput $args" rb]
		} elseif {![dict get? $tput_cache res $args]} {
			set res [::util::read_wrap "|tput $args" rb]
			dict set tput_cache $args $res
		}
		return $res
	}

	# Like above, but allows for multiple arguments
	proc tputm {args} {
		variable tput_cache

		set res {}
		foreach arg $args {
			if {$arg in {lines cols}} {
				set val [::util::read_wrap "|tput $arg" rb]
			} elseif {![dict get? $tput_cache val $arg]} {
				set val [::util::read_wrap "|tput $arg" rb]
				dict set tput_cache $arg $val
			}
			append res $val
		}
		return $res
	}

	# puts_attr ?-nonewline? ?channelId? attrlist string
	# Example: puts_attr {bold on fgcolor green} hello
	proc puts_attr {args} {
		global tcl_platform
		variable ecma48_sgr

		switch [llength $args] {
			2 {set chan stdout}
			3 {
				set first [lindex $args 0]
				set chan [? {$first eq "-nonewline"} stdout {$first}]
			}
			4 {set chan [lindex $args 1]}
			default {
				error "wrong # args: should be `puts_attr ?-nonewline? ?channelId? attrlist string`"
			}
		}
		if {$tcl_platform(platform) eq "unix" && [chan isatty $chan]} {
			set prefix [lreduceip [lindex $args end-1] "" {acc e1 e2} {
				append acc [dict get $ecma48_sgr $e1 $e2]
			}]
			set suffix [dict get $ecma48_sgr reset]
			puts {*}[lrange $args 0 end-2] $prefix[lindex $args end]$suffix
		} else {
			puts {*}[lreplace $args end-1 end-1]
		}
	}

                              ####################
                              # Misc utilities 2 #
                              ####################

	# Add/delete scripts to run when exiting. By default, scripts are run into the caller's
	# namespace.
	#
	# Example:
	#     % atexit add {puts "hello world"}
	#     % atexit add {puts [clock format [clock seconds]]}
	#     % atexit add {global env; puts "env: $env(HOME)"}
	#     % atexit del {puts "hello world"}
	#     % exit
	#     Wed Jul 14 14:27:58 CEST 2021
	#     env: /home/user
	variable atexit_scripts {}
	proc atexit {action script {ns ""}} {
		variable atexit_scripts

		if {$ns eq ""} {
			set ns [uplevel 1 namespace current]
		}
		set key [list $ns $script]
		switch $action {
			add {
				lappend atexit_scripts $key
			}
			del {
				set idx [lsearch -exact $atexit_scripts $key]
				if {$idx == -1} {
					error "atexit script `$script` not found in namespace `$ns`"
				} else {
					set atexit_scripts [lreplace $atexit_scripts $idx $idx]
				}
			}
			default {
				error "$action: must be `add` or `del`"
			}
		}
		return
	}
	trace add execution exit enter [lambda args {
		variable atexit_scripts
		foreach ns_script $atexit_scripts {
			namespace eval {*}$ns_script
		}
	}]
}
