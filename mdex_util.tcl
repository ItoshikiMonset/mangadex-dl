package require json
set scriptdir [file dirname [file dirname \
							 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]

set URL_BASE       https://mangadex.org
set URL_BASE_RE    https://mangadex\.org
set COVER_SERVER   https://uploads.mangadex.org
set API_URL_BASE   https://api.mangadex.org
set USER_AGENT     {Mozilla/5.0 (Windows NT 6.1; WOW64; rv:54.0) Gecko/20100101 Firefox/54.0}
set UUID_RE        {[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}}


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

# Wrapper around curl to download each URL to the corresponding outname
# args can be used as additional curl options
proc curl_map {urls outnames args} {
	foreach url $urls outname $outnames {
		lappend args -o $outname $url
	}
	curl {*}$args
}

# MangaDex GET API endpoint, with optional query parameters as a dict
proc api_get {endpoint {query_params ""}} {
	global API_URL_BASE

	set args {}
	foreach {key val} $query_params {
		lappend args --data-urlencode $key=$val
	}
	curl --get --no-progress-meter $API_URL_BASE/$endpoint {*}$args
}

# MangaDex JSON POST API endpoint
proc api_post_json {endpoint json} {
	global API_URL_BASE

	curl --request POST --header {Content-Type: application/json} --data $json --no-progress-meter \
		$API_URL_BASE/$endpoint
}

# Convert a Mangadex manga URL to its ID; mode can be "legacy"
proc manga_url_to_id {url {mode ""}} {
	global URL_BASE_RE UUID_RE

	if {$mode eq "legacy"} {
		if {![regexp "^$URL_BASE_RE/title/(\\d+)/\[^/\]+\$" $url -> id]} {
			util::die "$url: invalid legacy URL"
		}
	} else {
		if {![regexp "^$URL_BASE_RE/title/($UUID_RE)\$" $url -> id]} {
			util::die "$url: invalid URL"
		}
	}
	return $id
}

# Helper to get manga title from a relationships list
proc get_rel_title {relationships lang} {
	foreach rel $relationships {
		if {[dict get $rel type] ne "manga"} {
			continue
		}
		if {$lang ne "" && [dict exists $rel attributes title $lang]} {
			return [dict get $rel attributes title $lang]
		} else {
			return [dict get $rel id]
		}
	}
}

# Helper to get scanlation group names from a relationships list
# return {{No Group}} if no group was found
proc get_rel_groups {relationships} {
	set groups [lmap rel $relationships {
		if {[dict get $rel type] ne "scanlation_group"} {
			continue
		}
		dict get $rel attributes name
	}]
	util::? {$groups eq ""} {{No Group}} {$groups}
}

# Get chapter timestamp (using the publishAt field) in `clock seconds` format
proc get_chapter_tstamp {chapter_data} {
	clock scan [regsub {\+\d{2}:\d{2}$} [dict get $chapter_data attributes publishAt] {}] \
		-timezone :UTC -format %Y-%m-%dT%H:%M:%S
}

# Produce a pretty chapter dirname, if title is specified, it overrides the remote one
proc chapter_dirname {chapter_data lang {title ""}} {
	if {$title eq ""} {
		set title [get_rel_title [dict get $chapter_data relationships] $lang]
	}
	set ret "$title - c"
	set num [dict get $chapter_data attributes chapter]
	if {[string is entier -strict $num]} {
		append ret [format %03d $num]
	} elseif {[string is double -strict $num]} {
		append ret [format %05.1f $num]
	} else {
		append ret $num
	}
	set vol [dict get $chapter_data attributes volume]
	if {$vol ne "null"} {
		if {[string is entier -strict $vol]} {
			append ret " (v[format %02d $vol])"
		} elseif {[string is double -strict $vol]} {
			append ret " (v[format %04.1f $vol])"
		} else {
			append ret " (v$vol)"
		}
	}
	set group_names [get_rel_groups [dict get $chapter_data relationships]]
	append ret " \[[join $group_names {, }]\]"
}

# Produce a pretty cover filename, if title is specified, it overrides the remote one
proc cover_filename {cover_data lang {title ""}} {
	if {$title eq ""} {
		set title [get_rel_title [dict get $cover_data relationships] $lang]
	}
	set ret "$title - c000"
	set vol [dict get $cover_data attributes volume]
	if {$vol ne "null"} {
		if {[string is entier -strict $vol]} {
			append ret " (v[format %02d $vol])"
		} elseif {[string is double -strict $vol]} {
			append ret " (v[format %04.1f $vol])"
		} else {
			append ret " (v$vol)"
		}
	}
	set ext [file extension [dict get $cover_data attributes fileName]]
	append ret " - Cover$ext"
}

# Get a single chapter from its id
proc get_chapter {cid} {
	set query_params {
		includes[] scanlation_group
		includes[] manga
	}
	puts stderr "Downloading chapter JSON..."
	set chapter [json::json2dict [api_get chapter/$cid $query_params]]
	if {[dict get $chapter result] eq "error"} {
		error [dict get $chapter errors]
	}
	return [dict get $chapter data]
}

# Get the complete chapter list (from smallest to greatest chapter number) for a manga id
# with an optional language filter
proc get_chapter_list {mid lang} {
	set query_params {
		limit          500
		offset         0
		order[chapter] asc
		includes[]     scanlation_group
		includes[]     manga
	}
	if {$lang ne ""} {
		lappend query_params {translatedLanguage[]} $lang
	}
	puts stderr "Downloading manga feed JSON..."
	util::do {
		set manga_feed [json::json2dict [api_get manga/$mid/feed $query_params]]
		dict incr query_params offset 500
		# Filter invalid chapters
		lappend chapters {*}[dict get $manga_feed data]
	} while {[dict get $manga_feed total] - [dict get $query_params offset] > 0}
	return $chapters
}


# Download the pages of a chapters in dirname from its JSON dict
proc dl_chapter {chapter_data dirname} {
	puts stderr "Downloading @Home server URL JSON..."
	set json [api_get at-home/server/[dict get $chapter_data id]]
	set server [dict get [json::json2dict $json] baseUrl]

	set hash [dict get $chapter_data attributes hash]
	set pages [dict get $chapter_data attributes data]

	set urls [util::lprefix $pages $server/data/$hash/]
	set outnames [lmap num [util::iota [llength $pages] 1] page $pages {
		format %0*d%s [string length [llength $pages]] $num [file extension $page]
	}]
	curl_map $urls [util::lprefix $outnames $dirname/]
}

# Download the covers of a manga in cwd. If volumes is specified, download
# only the covers for these
proc dl_covers {mid lang {volumes ""}} {
	global COVER_SERVER

	set query_params {
		limit         100
		offset        0
		order[volume] asc
		includes[]    manga
	}
	lappend query_params {manga[]} $mid

	puts stderr "Downloading cover list JSON..."
	if {[catch {api_get cover $query_params} json]} {
		util::die "Failed to download cover list JSON!\n\n$json"
	}
	set json [json::json2dict $json]
	if {[dict get $json result] ne "ok"} {
		error "Wrong result returned: [dict get $json errors]"
	}
	foreach cov [dict get $json data] {
		if {$volumes eq "" || [dict get $cov attributes volume] in $volumes} {
			lappend urls $COVER_SERVER/covers/$mid/[dict get $cov attributes fileName]
			lappend outnames [cover_filename $cov $lang]
		}
	}
	curl_map $urls $outnames
}
