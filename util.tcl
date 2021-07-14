namespace path {::tcl::mathop ::tcl::mathfunc}

namespace eval util {
	source [file join [info library] init.tcl]
	catch {package require Tclx}
	namespace path {::tcl::mathop ::tcl::mathfunc}
	namespace export *

                               ##################
                               # Misc utilities #
                               ##################

	proc ::tcl::chan::isatty {chan} {
		::tcl::mathop::! [catch {chan configure $chan -mode}]
	}

	namespace ensemble configure chan -map \
		[linsert [namespace ensemble configure chan -map] end \
			 isatty  ::tcl::chan::isatty]

	# Add/delete scripts to run when exiting (incl. calls to exit and error)
	# Syntax is `atexit add|del script`, scripts are run in the global namespace
	#
	# Example:
	#     util::atexit add {puts "hello world"}
	#     util::atexit add {puts [clock format [clock seconds]]}
	#     util::atexit add {global env; puts "env: $env(HOME)"}
	#     util::atexit del {puts "hello world"}
	#
	# will print
	#     Wed Jul 14 14:27:58 CEST 2021
	#     env: /home/user
	#
	# when reaching the end
	variable atexit_scripts {}
	proc atexit {args} {
		variable atexit_scripts
		lassign $args mode script
		switch $mode {
			add {
				lappend atexit_scripts $script
			}
			del {
				set idx [lsearch -exact $atexit_scripts $script]
				set atexit_scripts [lreplace $atexit_scripts $idx $idx]
			}
			default {
				error "$mode: must be \"add\" or \"del\""
			}
		}
		return
	}
	trace add execution exit enter [list apply \
		[list args \
			 "foreach script \$util::atexit_scripts {eval \$script}" \
			] \
		]

	# Identity
	proc id {x} {
		string cat $x
	}

	proc decr {_x {decrement 1}} {
		upvar $_x x
		incr x -$decrement
	}

	proc until {test body} {
		uplevel 1 [list while !($test) $body]
	}

	# Random integer in range [0, max[
	proc irand {max} {
		int [* [rand] $max]
	}

	proc do {body keyword test} {
		if {$keyword eq "while"} {
			set test "!($test)"
		} elseif {$keyword ne "until"} {
			return -code error "unknown keyword \"$keyword\": must be until or while"
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
		uplevel "global argv; set argv \[lassign \$argv $args\]"
		decr argc $argnum
		return 1
	}

	# Graceful death, don't unwind like error
	proc die {msg {code 1}} {
		puts stderr $msg
		exit $code
	}

	# Execute body every ms milliseconds or cancel an existing every
	proc every {ms body} {
		global every tcl_interactive
		if {$ms eq "cancel"} {
			after cancel [dict get $every $body]
			dict unset every $body
			return
		}
		eval $body
		dict set every $body [namespace code [info level 0]]
		tailcall after $ms [namespace code [info level 0]]
	}

	# Like textutil::adjust followed by textutil::indent with the following
	# differences :
	# * Add terminal markup and handles it properly (don't count the ECMA sequences in text width).
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
		time {set opts [dict merge \
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
			dict assign $opts} 1
		if {![string is ascii text] && ![catch {package require textutil}] &&
			![catch {package present textutil::wcswidth}]} {
			interp alias {} textwidth {} ::textutil::wcswidth
		} else {
			interp alias {} textwidth {} ::tcl::string::length
		}

		if {!$dumb} {
			# cf ECMA-48 SGR
			set codes [dict create \
						   bold      [dict create 1 \x1b\[1m 0 \x1b\[22m] \
						   dim       [dict create 1 \x1b\[2m 0 \x1b\[22m] \
						   underline [dict create 1 \x1b\[4m 0 \x1b\[24m] \
						   blink     [dict create 1 \x1b\[5m 0 \x1b\[25m] \
						   reverse   [dict create 1 \x1b\[7m 0 \x1b\[27m] \
						   strike    [dict create 1 \x1b\[9m 0 \x1b\[29m]]
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
										   dict get \$codes $attr 0
									   } else {
										   dict set state $attr 1
										   dict get \$codes $attr 1
									   }\]"
					}
					2 {
						lappend map [lindex $sym 0]
						lappend map "\[dict set state $attr 1
									   dict get \$codes $attr 1\]"
						lappend map [lindex $sym 1]
						lappend map "\[dict set state $attr 0
									   dict get \$codes $attr 0\]"
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
	# Modify argv and argc to only leave the arguments.
	# Create a usage proc in this namespace to get the help message as a string.
	# Returns the parsed options in the same form as optspec but with values filled with
	# the parsed value or specified default. Flag value is 1 if found, 0 otherwise.
	proc autocli {optspec name short_descr synargslist {long_descr ""}} {
		global argv argc

		set body [join [list [list set optspec $optspec] \
					  [list set name $name] \
					  [list set short_descr $short_descr] \
					  [list set synargslist $synargslist] \
					  [list set long_descr $long_descr]] \
				 \n]
		append body {
			set tabw 4
			set printw [min [array unset ::env COLUMNS; ::util::read_wrap "|tput cols" rb] 80]
			set opts [dict create \
						  width $printw \
						  dumb [! [chan isatty stdout]] \
						 ]
			append msg [format_paragraph **NAME** {*}$opts]\n
			append msg [format_paragraph "$name - $short_descr" indent $tabw {*}$opts]\n
			append msg \n
			append msg [format_paragraph **SYNOPSIS** {*}$opts]\n
			set synindent [+ [string length $name] $tabw 1]
			set synopts {}
			foreach synargs $synargslist {
				append msg "[format_paragraph "**$name**" indent $tabw {*}$opts] "
				if {$optspec ne ""} {
					set synargs "\[OPTION\]... $synargs"
				}
				regsub -all {\w+}  $synargs {__&__} synargs
				regsub -all {[][]} $synargs {**&**} synargs
				append msg [string trimleft [format_paragraph $synargs indent $synindent {*}$opts]]\n
			}
			append msg \n
			if {$long_descr ne ""} {
				append msg [format_paragraph **DESCRIPTION** {*}$opts]\n
				foreach par $long_descr {
					if {$par eq ""} {
						append msg \n
						continue
					}
					set indent [+ [string length [regexp -inline {^ +} $par]] $tabw]
					append msg [format_paragraph $par indent $indent {*}$opts]\n
				}
			}
			append msg \n
			append msg [format_paragraph **OPTIONS** {*}$opts]\n
			dict set optspec help {flag "Print this help message and exit."}
			dict for {key val} $optspec {
				if {[lindex $val 0] eq "flag"} {
					append msg [format_paragraph "**-$key**" indent $tabw {*}$opts]\n
					foreach par [lrange $val 1 end] {
						append msg [format_paragraph $par indent [* $tabw 2] {*}$opts]\n
					}
				} else {
					set par "**-$key**[? {[llength $val] >= 4} { __[lindex $val 2]__}]"
					append msg [format_paragraph $par indent $tabw {*}$opts]\n
					foreach par [lrange $val 3 end] {
						append msg [format_paragraph $par indent [* $tabw 2] {*}$opts]\n
					}
					if {[lindex $val 1] ne ""} {
						append msg [format_paragraph "Defaults to \"[lindex $val 1]\"." \
										indent [* $tabw 2] {*}$opts]\n
					}
				}
				append msg \n
			}
			return [string range $msg 0 end-1]; # Remove extraneous newline
		}
		proc usage {} $body

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
				-help {puts [usage]; exit}
				-?* {
					set key [string range $arg 1 end]
					if {[dict get? $optspec val $key]} {
						set val [lindex $val 0]
						switch $val {
							flag {dict set result $key 1}
							param {
								if {![shift param]} {
									die "option $arg requires a parameter\n\n[usage]"
								}
								dict set result $key $param
							}
						}
					} else {
						die "$arg: unknown option\n\n[usage]"
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

                              ####################
                              # String utilities #
                              ####################

	# Split a string into block of size chars (last block can be of inferior size)
	proc block_split {str size} {regexp -inline -all ".{1,$size}" $str}

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
	proc lfilter {var lst test} {
		tailcall lmap $var $lst [list if $test [list set $var] else continue]
	}

	# Traditional FP foldl. args contains the command
	# Examples:
	#     lfoldl {1 2 3} 0 +            => 6
	#     lfoldl {1 2 3} "" string cat  => 123
	proc lfoldl {lst init args} {
		foreach elem $lst {
			set init [uplevel 1 $args [list $init $elem]]
		}
		return $init
	}

	# Opposite of lappend
	proc lprepend {_lst args} {
		upvar $_lst lst
		lappend lst ;# Used as a an "is a list" check and to do var creation
		set lst [linsert $lst [set lst 0] {*}$args]
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
	proc lincr {_lst index {increment 1}} {
		upvar $_lst lst
		lset lst $index [+ [lindex $lst $index] $increment]
	}

	# lassign _lst and set it to the result immediately; returns nothing
	proc lshift {_lst args} {
		uplevel "set [list $_lst] \[lassign \$[list $_lst] $args\]"
	}

	# Append suffix to all the elements of list and return the resulting list
	proc lsuffix {lst suffix} {
		lmap x $lst {id $x$suffix}
	}

	# Prepend prefix to all the elements of list and return the resulting list
	proc lprefix {lst prefix} {
		lmap x $lst {id $prefix$x}
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
		::upvar $_var var
		if {[exists $dict {*}$args]} {
			::set var [get $dict {*}$args]
			return 1
		}
		return 0
	}

	# Assign the dict values to key-named variables (with s/[ -]/_/g applied to
	# them).
	proc ::tcl::dict::assign {dict} {
		uplevel [list lassign [dict values $dict]] \
			[lmap s [dict keys $dict] {string map {- _ " " _} $s}]
	}

	# dict append with support for nested dictionaries while appending
	# only one element
	proc ::tcl::dict::appendn {_dict args} {
		upvar 1 $_dict d
		::set keys [::lrange $args 0 end-1]
		::set appdarg [::lindex $args end]
		try {
			set d {*}$keys [list {*}[get $d {*}$keys] $appdarg]
		} on error {} {
			set d {*}$keys [list $appdarg]
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
		::set addarg [::lindex $args end]
		try {
			set d {*}$keys [::tcl::mathop::+ [get $d {*}$keys] $addarg]
		} on error {} {
			set d {*}$keys $addarg
		}
	}

	namespace ensemble configure dict -map \
		[linsert [namespace ensemble configure dict -map] end \
			 get?    ::tcl::dict::get? \
			 assign  ::tcl::dict::assign \
			 appendn ::tcl::dict::appendn \
			 incrn   ::tcl::dict::incrn \
			 add     ::tcl::dict::add]
}

namespace import util::?
