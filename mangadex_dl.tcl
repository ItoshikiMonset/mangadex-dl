#!/usr/bin/env tclsh
# TODO: group filtering ?
set scriptdir [file dirname [file dirname \
							 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]
source [file join $scriptdir mangadex_util.tcl]

if {![executable_check curl]} {
	die "curl executable not found"
}


# Option and argument handling
autocli usage opts \
	[file tail [info script]] \
	"download Mangadex chapters" \
	"\[OPTIONS\] SERIE_URL \[CHAPTER...\]" \
	{
		"Download each of the specified chapters into its own properly named"
		"directory. If no chapter is specified, download all of them."
	} \
	{
		proxy      {param ""   PROXY_URL "Set the curl HTTP/HTTPS proxy."}
		first-page {param 0    PAGE_NO   "Start downloading from PAGE_NO (see lrange(n))."}
		last-page  {param end  PAGE_NO   "Stop downloading at PAGE_NO."}
		lang       {param "gb" LANG_CODE "Only download chapters in this language."}
	}
dictassign $opts

if {$argc < 1} {
	die $usage
}
shift serie_url

if {$proxy ne ""} {
	set ::env(http_proxy)  $proxy
	set ::env(https_proxy) $proxy
}


# Download serie JSON
if {![regexp {https://mangadex\.org/title/(\d+)/[^/]+} $serie_url -> serie_id]} {
	die "$serie_url: invalid mangadex URL"
}
puts "Downloading serie JSON..."
set root [json_dl https://mangadex.org/api/manga/$serie_id]

# Filter chapters by language then number if required
set chapters [dict get $root chapter]
if {$lang ne ""} {
	set chapters [dict filter $chapters script {key val} \
					  {string equal [dict get $val lang_code] $lang}]
}
if {$argc >= 1} {
	set chapters [dict filter $chapters script {key val} \
					  {in [dict get $val chapter] $argv}]
}

# Iterate over the filtered chapters and download
set orig_pwd [pwd]
set serie_title [dict get $root manga title]
foreach {chapter_id chapter_data} $chapters {
	set chapter_name [chapter_format_name $serie_title $chapter_data]
	set outdir [path_sanitize $chapter_name]
	file mkdir $outdir
	cd $outdir
	puts "Downloading $chapter_name..."
	chapter_dl $chapter_id $first_page $last_page
	cd $orig_pwd
}
