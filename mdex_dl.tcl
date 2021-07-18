#!/usr/bin/env tclsh
# TODO: group filtering ?
set scriptdir [file dirname [file dirname \
								 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]
source [file join $scriptdir mdex_util.tcl]
util::exec_require curl


# Option and argument handling
set optres [util::autocli \
	{
		proxy  {param {}   PROXY_URL {Set the curl HTTP/HTTPS proxy.}}
		lang   {param {en} LANG_CODE {Only download chapters in this language.}}
		covers {flag                 {Download the manga covers too.}}
	} \
	[file tail [info script]] \
	{download MangaDex chapters} \
	{{MANGA_URL [CHAPTER...]} {CHAPTER_URL...}} \
	{
		{Download each of the specified chapters into its own properly named directory.}
		{If no chapter is specified, download all of them.}
	}]

if {$argc == 0} {
	util::usage stderr 1
}

dict assign $optres
if {$proxy ne ""} {
	set ::env(http_proxy)  $proxy
	set ::env(https_proxy) $proxy
}

if {[regexp "^$URL_BASE_RE/title/($UUID_RE)\$" [lindex $argv 0] -> mid]} {
	if {[catch {get_chapter_list $mid $lang} chapters]} {
		util::die "Failed to download chapter list JSON!\n\n$chapters"
	}
	# Only keep specified chapters
	if {$argc > 0} {
		set chapters [util::lfilter ch $chapters {[dict get $ch data attributes chapter] in $argv}]
	}
} else {
	set cids [lmap url $argv {
		if {![regexp "^$URL_BASE_RE/chapter/($UUID_RE)\$" $url -> cid]} {
			util::die "$url: not a chapter URL"
		}
		set cid
	}]
	set chapters [lmap cid $cids {
		if {[catch {get_chapter $cid} chapter]} {
			puts stderr "Failed to download chapter $cid JSON\n\n$chapter"
			continue
		}
		if {$argc > 5} {
			after 300; # Sleep to avoid hitting the rate limit of 5 req/s
		}
		set chapter
	}]
}

# Iterate over the filtered chapters and download
foreach ch $chapters {
	set outdir [util::path_sanitize [chapter_dirname $ch $lang]]
	if {[file exists $outdir] && ![util::is_dir_empty $outdir]} {
		continue
	}
	file mkdir $outdir
	puts stderr "\[[incr count]/[llength $chapters]\] Downloading $outdir..."
	if {[catch {dl_chapter $ch $outdir} err]} {
		puts stderr "Failed to download $outdir!\n\n$err"
		file delete -force -- $outdir
	}
}

if {$covers} {
	# TODO: only download the relevant volumes ?
	dl_covers $manga_id $lang
}
