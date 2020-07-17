package require json
set scriptdir [file dirname [file dirname \
							 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]

set URL_BASE https://mangadex.org
set USER_AGENT {Mozilla/5.0 (Windows NT 6.1; WOW64; rv:54.0) Gecko/20100101 Firefox/54.0}


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

# Wrapper to set common curl options
proc curl {args} {
	global USER_AGENT
	exec -ignorestderr curl \
		--compressed \
		--connect-timeout 5 \
		--fail \
		--fail-early \
		--location \
		--max-time 15 \
		--retry 5 \
		--user-agent $USER_AGENT \
		{*}$args
}

# Trivial wrapper
proc api_dl {arg id} {
	global URL_BASE
	curl --no-progress-meter $URL_BASE/api/$arg/$id
}

# Download the pages of a chapters starting at page $first and ending at page
# $last in the CWD
proc chapter_dl {chapter_id} {
	set json [json::json2dict [api_dl chapter $chapter_id]]
	dict assign $json
	curl --remote-name-all $server$hash/\{[join $page_array ,]\}
	rename_mtime .
}
