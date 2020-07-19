namespace path {::tcl::mathop ::tcl::mathfunc}

# Ternary
proc ter {expr a {b ""}} {
	tailcall if $expr [list string cat $a] else [list string cat $b]
}

# Graceful death, don't unwind like error.
proc die {msg {code 1}} {
	puts stderr $msg
	exit $code
}

# Useful open/read/close wrapper.
proc read_file {path} {
	if {[catch {open $path} chan]} {
		die $chan
	}
	set result [read $chan]
	close $chan
	return $result
}

# Useful open/puts/close wrapper.
proc write_file {path data} {
	if {[catch {open $path w} chan]} {
		die $chan
	}
	puts $chan $data
	close $chan
}

# Like lmap, but expr is used as an if argument to filter values
proc lfilter {var list expr} {
	tailcall lmap $var $list [list if $expr [list set $var] continue]
}

# Opposite of lappend.
proc lprepend {_var args} {
	upvar $_var var
	lappend var ;# Used as a an "is a list" check and to do var creation
	set var [linsert $var [set var 0] {*}$args]
}

# Like shift(1).
proc shift {var args} {
	lprepend args $var
	set argslen [llength $args]
	global argc
	if {$argslen > $argc} {
		return 0
	}
	uplevel "global argv; set argv \[lassign \$argv $args\]"
	set argc [expr {$argc - $argslen}]
	return 1
}

# Assign the dict values to key-named variables (with s/[ -]/_/g applied to
# them).
proc ::tcl::dict::assign {dict} {
	uplevel [list lassign [dict values $dict]] \
		[lmap s [dict keys $dict] {string map {- _ " " _} $s}]
}

# Conditional dict get, sets _var only if the key is to be found in dict.
# Returns 1 if it was found, 0 otherwise.
proc ::tcl::dict::get? {dict _var args} {
	::upvar $_var var
	if {[dict exists $dict {*}$args]} {
		::set var [dict get $dict {*}$args]
		return 1
	}
	return 0
}
namespace ensemble configure dict -map \
    [linsert [namespace ensemble configure dict -map] end \
		 get? ::tcl::dict::get? assign ::tcl::dict::assign]

# All-in-one CLI creation. Sets a pretty help notice and parses argv according
# to flag/parametric options of the form "-opt ?param?".
#
# _help: variable to store the help.
# _optres: variable to store the option parsing result. Same form as optspec
#          but with values filled by the passed or default value. Flag value
#          is 1 if found, 0 otherwise.
# name: executable name.
# short_descr: description in a few words.
# synopsis: what comes after the executable name in the usual man(1) format.
# long_descr: optional long description in the form of list of lines.
# optspec: dict of the form {key val} with
#     key: option name without starting dash
#     val: either {"flag" ?optdescr_line ...?}
#                   or
#                 {"param" default_value ?val_name optdescr_line ...?}
#
# Modify argv and argc to only leave the arguments. Returns nothing.
proc autocli {_help _optres name short_descr synopsis {long_descr ""} optspec} {
	upvar $_help help $_optres result
	global argv argc

	set help "NAME\n    $name - $short_descr\n"
	append help "\nSYNOPSIS\n    $name $synopsis\n"
	if {$long_descr ne ""} {
		append help "\nDESCRIPTION\n"
		append help [join [lmap x $long_descr {string cat "    $x"}] \n]
		append help \n
	}
	append help "\nOPTIONS\n"
	append help "    -help\n"
	append help "        Print this help message and exit.\n"

	set result [dict create]
	dict for {key val} $optspec {
		if {![string is list $val]} {
			error "$val: invalid optspec value for key $key; not a valid list"
		}
		set type [lindex $val 0]
		set vallen [llength $val]
		if {$type eq "flag"} {
			dict set result $key 0
			append help "\n    -$key\n"
			foreach line [lrange $val 1 end] {
				append help "        $line\n"
			}
		} elseif {$type eq "param"} {
			if {$vallen < 2} {
				error "$val: invalid optspec value for key $key; missing default value"
			}
			set default [lindex $val 1]
			dict set result $key $default
			append help "\n    -$key"
			if {$vallen >= 4} {
				append help " [lindex $val 2]"
			}
			append help \n
			foreach line [lrange $val 3 end] {
				append help "        $line\n"
			}
			if {$default ne ""} {
				append help "        Defaults to \"$default\".\n"
			}
		} else {
			error "$val: invalid optspec value for key $key; invalid opt type"
		}
	}

	while {[shift arg]} {
		switch -glob -nocase -- $arg {
			-- {break}
			-help {die $help 0}
			-?* {
				set key [string range $arg 1 end]
				if {[dict get? $optspec val $key]} {
					set val [lindex $val 0]
					switch $val {
						flag {dict set result $key 1}
						param {
							if {![shift param]} {
								die "option $arg requires a parameter\n\n$help"
							}
							dict set result $key $param
						}
					}
				} else {
					die "$arg: unknown option\n\n$help"
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

# Remove some forbidden/annoying characters from str when used as POSIX path.
proc path_sanitize {str} {
	string map {/ _ \n " " \r ""} $str
}

# Check if a binary can be found by the sh(1)/exec[lv]p(3).
proc executable_check {exename} {
	! [catch [list exec sh -c [list command -v $exename] >/dev/null]]
}

proc is_dir_empty {path} {
	if {![file isdirectory $path]} {
		error "$path: not a directory"
	}
	set glob [glob -nocomplain -tails -directory $path * .*]
	eq [lfilter x $glob {$x ne  "." && $x ne ".."}] ""
}


# glob wrapper sorting by mtime
proc glob_mtime {args} {
	lmap x [lsort -integer -index 0 \
				[lmap x [glob {*}$args] {list [file mtime $x] $x}]] \
		{lindex $x 1}
}

# Rename all the files in dir according to their mtime
proc rename_mtime {dir} {
	set paths [glob_mtime -directory $dir *]
	set fmt %0[string length [llength $paths]]u
	foreach path $paths {
		incr count
		set target [file join $dir [format $fmt $count][file extension $path]]
		file rename -- $path $target
	}
}
