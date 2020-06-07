#!/usr/bin/env tclsh
# TODO: group preference, override serie name ?
package require json
source [file join [file dirname [info script]] util.tcl]

proc json_dl {url} {
	json::json2dict [exec curl -sL $url]
}

proc compute_dirname {serie ch_info} {
	set ret "$serie - c"
	set ch [dict get $ch_info chapter]
	if {[string is entier $ch]} {
		set ch [format %03d $ch]
	} elseif {[string is double $ch]} {
		set ch [format %05.1f $ch]
	}
	append ret $ch
	set vol [dict get $ch_info volume]
	if {$vol ne ""} {
		append ret " ([format v%02d $vol])"
	}
	set group [dict get $ch_info group_name]
	set group2 [dict get $ch_info group_name_2]
	set group3 [dict get $ch_info group_name_3]
	if {$group2 ne "null"} {
		append group ", $group2"
	}
	if {$group3 ne "null"} {
		append group ", $group3"
	}
	append ret " \[[string map {/ _} $group]\]"
	return $ret
}

proc chapter_dl {ch_dat first last} {
	set base_url "[dict get $ch_dat server][dict get $ch_dat hash]/"
	set pages [lrange [dict get $ch_dat page_array] $first $last]
	exec -ignorestderr curl -L --remote-name-all \
		{*}[lmap x $pages {string cat $base_url $x}]
}


set usage "Usage: [file tail [info script]] \[OPTIONS\] SERIE_URL \[CHAPTER...\]"
set opt [getopt {
	proxy      {param ""   PROXY_URL "Set the curl HTTP/HTTPS proxy."}
	first-page {param 0    PAGE_NO   "Start downloading from PAGE_NO (see lrange(n))."}
	last-page  {param end  PAGE_NO   "Stop downloading at PAGE_NO."}
	lang       {param "gb" LANG_CODE "Only download chapters in this language."}
} usage]

if {$argc < 1} {
	die $usage
}

optassign $opt
if {$proxy ne ""} {
	set ::env(http_proxy)  $proxy
	set ::env(https_proxy) $proxy
}
set argv [lassign $argv serie_url]


if {![regexp {https://mangadex\.org/title/(\d+)/[^/]+} $serie_url -> serie_id]} {
	die "$serie_url: wrong URL"
}
puts "Downloading serie JSON..."
set root [json_dl https://mangadex.org/api/manga/$serie_id]
set chapters [dict filter [dict get $root chapter] script {key val} \
				  {expr {[dict get $val lang_code] eq $lang}}]
if {$argc > 1} {
	set chapters [dict filter $chapters script {key val} \
					  {expr {[dict get $val chapter] in $argv}}]
}
foreach {ch_id ch_info} $chapters {
	set dir [compute_dirname [dict get $root manga title] $ch_info]
	set ch_num [dict get $ch_info chapter]
	puts "Downloading chapter $ch_num JSON..."
	set ch_dat [json_dl https://mangadex.org/api/chapter/$ch_id]
	file mkdir $dir
	cd $dir
	puts "Downloading chapter $ch_num data..."
	chapter_dl $ch_dat $first_page $last_page
	cd ..
}
