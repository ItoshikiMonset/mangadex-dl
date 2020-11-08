package require json
set scriptdir [file dirname [file dirname \
							 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]

set URL_BASE https://mangadex.org
set USER_AGENT {Mozilla/5.0 (Windows NT 6.1; WOW64; rv:54.0) Gecko/20100101 Firefox/54.0}


# Produce a daiz approved name for a chapter
proc chapter_caption {serie_title chapter_data group_names} {
	dict assign $chapter_data
	set ret "$serie_title - c"

	if {[string is entier -strict $chapter]} {
		append ret [format %03d $chapter]
	} elseif {[string is double -strict $chapter]} {
		append ret [format %05.1f $chapter]
	} else {
		append ret $chapter
	}
	if {$volume ne ""} {
		append ret " ([format v%02d $volume])"
	}
	append ret " \[[join $group_names {, }]\]"
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
		--max-time 30 \
		--retry 5 \
		--user-agent $USER_AGENT \
		{*}$args
}

# Wrapper around curl to download each url to the corresponding outname
# args is used as additional arguments
proc curl_map {urls outnames args} {
	foreach url $urls outname $outnames {
		lappend args -o $outname $url
	}
	curl {*}$args
}

# Trivial mangadex api download wrapper
proc api_dl args {
	global URL_BASE
	curl --no-progress-meter $URL_BASE/api/v2/[join $args /]
}

# Download the pages of a chapters starting at page $first and ending at page
# $last in the CWD
proc chapter_dl {chapter_id} {
	set json [json::json2dict [api_dl chapter $chapter_id]]

	set code [dict get $json code]
	if {$code != 200} {
		error "Code $code (status [dict get $json status]) received"
	}

	dict assign [dict get $json data]

	set urls [lprefix $pages $server$hash/]
	set outnames [lmap num [lseq_zerofmt 1 [llength $pages]] page $pages {
		string cat $num [file extension $page]
	}]

	if {[catch {curl_map $urls $outnames} err errdict]} {
		if {[info exists serverFallback]} {
			puts stderr "Trying fallback server"
			set urls [lprefix $pages $serverFallback$hash/]
			curl_map $urls $outnames --continue-at -
		} else {
			dict incr errdict -level
			return -options $errdict $err
		}
	}
}
