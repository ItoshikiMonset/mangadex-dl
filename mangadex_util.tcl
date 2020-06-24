package require json
set scriptdir [file dirname [file dirname \
							 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]


# Produce a daiz approved name for a chapter
proc chapter_format_name {serie_name chapter_info} {
	dict assign $chapter_info
	set ret "$serie_name - c"

	if {[string is entier $chapter]} {
		append ret [format %03d $chapter]
	} elseif {[string is double $chapter]} {
		append ret [format %05.1f $chapter]
	} else {
		append ret $chapter
	}
	if {$volume ne ""} {
		append ret " ([format v%02d $volume])"
	}
	set groups $group_name
	if {$group_name_2 ne "null"} {
		append groups ", $group_name_2"
	}
	if {$group_name_3 ne "null"} {
		append groups ", $group_name_3"
	}
	append ret " \[$groups\]"
}

# Trivial wrapper
proc json_dl {url} {
    json::json2dict [exec curl -sL $url]
}

# Download the pages of a chapters starting at page $first and ending at page
# $last in the CWD
proc chapter_dl {chapter_id {first 0} {last end}} {
	set json [json_dl https://mangadex.org/api/chapter/$chapter_id]
	dict assign $json

	set urls [lmap x [lrange $page_array $first $last] \
				  {string cat $server$hash/ $x}]
	exec -ignorestderr curl --location --remote-name-all --connect-timeout 20 \
		--retry 5 {*}$urls
}
