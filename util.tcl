# Graceful death, don't unwind like error
proc die {msg {code 1}} {
	puts stderr $msg
	exit $code
}

# Opposite of lappend
proc lprepend {_var args} {
	upvar $_var var
	lappend var ;# Used as a an "is a list" check and to do var creation
	set var [linsert $var [set var 0] {*}$args]
}

# Like shift(1)
proc shift {_var {count 1}} {
	upvar $_var var
	global argv argc

	if {$argc >= $count} {
		incr count -1
		set var [lrange $argv 0 $count]
		set argv [lreplace $argv 0 $count]
		incr argc -1
		return 1
	}
	return 0
}

# getopt working on flags and parametric options of the form "-opt ?param?"
#
# optspec: dict of the form {key val} with
#     key: option name without starting dash
#     val: either {"flag" ?optdescr?} or
#                 {"param" default_value ?val_name optdescr?}
#
# _helpstr: variable containing the help message, to be augmented with the
#           formatted options description
#
# Returns a dict of the form {key val} with
#     key: same as optspec
#     val: input or default value; options of type "flag" have a value of 1 if
#          found and 0 as default
proc getopt {optspec _helpstr} {
	upvar $_helpstr helpstr
	global argv argc

	if {[info exists helpstr]} {
		append helpstr \n\n
	}
	append helpstr OPTIONS\n
	append helpstr "    -help\n"
	append helpstr "        Print this help message and exit.\n"

	set result [dict create]
	dict for {key val} $optspec {
		if {![string is list $val]} {
			error "$val: invalid optspec value for key $key; not a valid list"
		}
		set type [lindex $val 0]
		set vallen [llength $val]
		if {$type eq "flag"} {
			dict set result $key 0
			append helpstr "\n    -$key\n"
			if {$vallen == 2} {
				append helpstr "        [lindex $val 1]\n"
			}
		} elseif {$type eq "param"} {
			if {$vallen < 2} {
				error "$val: invalid optspec value for key $key; missing default value"
			}
			dict set result $key [lindex $val 1]
			append helpstr "\n    -$key"
			if {$vallen == 4} {
				append helpstr " [lindex $val 2]"
			}
			append helpstr \n
			if {$vallen == 3 || $vallen == 4} {
				append helpstr "        [lindex $val end]\n"
			}
		} else {
			error "$val: invalid optspec value for key $key; invalid opt type"
		}
	}

	while {[shift arg]} {
		switch -glob -nocase -- $arg {
			-- {break}
			-help {die $helpstr 0}
			-?* {
				set key [string range $arg 1 end]
				if {[dict exists $optspec $key]} {
					set val [lindex [dict get $optspec $key] 0]
					switch $val {
						flag {dict set result $key 1}
						param {
							if {![shift param]} {
								die "option $arg requires a parameter\n\n$helpstr"
							}
							dict set result $key $param
						}
					}
				} else {
					die "$arg: unknown option\n\n$helpstr"
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

# Assign the dict values to key-named variables (with s/-/_/g applied to them)
proc optassign {optres} {
	uplevel [list lassign [dict values $optres]] \
		[lmap s [dict keys $optres] {string map {- _} $s}]
}
