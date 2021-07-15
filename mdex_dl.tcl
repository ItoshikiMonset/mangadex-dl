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
    {{MANGA_URL [CHAPTER...]}} \
	{
		{Download each of the specified chapters into its own properly named directory.}
		{If no chapter is specified, download all of them.}
	}]

if {$argc < 1} {
	util::die [util::usage]
}
util::shift manga_url

dict assign $optres
if {$proxy ne ""} {
	set ::env(http_proxy)  $proxy
	set ::env(https_proxy) $proxy
}


set manga_id [manga_url_to_id $manga_url]
if {[catch {get_chapter_list $manga_id $lang} chapters]} {
	util::die "Failed to download chapter list JSON!\n\n$chapters"
}

# Only keep specified chapters
if {$argc > 0} {
	set chapters [util::lfilter ch $chapters {[dict get $ch data attributes chapter] in $argv}]
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
