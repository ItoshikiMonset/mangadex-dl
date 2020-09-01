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
		lang       {param "gb" LANG_CODE "Only download chapters in this language."}
		covers     {flag                 "Download the serie covers too."}
	}
dict assign $opts

if {$argc < 1} {
	die $usage
}
shift serie_url

if {$proxy ne ""} {
	set ::env(http_proxy)  $proxy
	set ::env(https_proxy) $proxy
}


# Download serie JSON
if {![regexp {https://(?:www\.)?mangadex\.org/title/(\d+)/[^/]+} $serie_url -> serie_id]} {
	die "$serie_url: invalid mangadex URL"
}
puts "Downloading serie JSON..."
if {[catch {api_dl manga $serie_id} json]} {
	die "Failure to download serie JSON!\n\n$err"
}
set root [json::json2dict $json]

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
set total [llength [dict keys $chapters]]
set orig_pwd [pwd]
set serie_title [dict get $root manga title]
foreach {chapter_id chapter_data} $chapters {
	set chapter_name [chapter_format_name $serie_title $chapter_data]
	set outdir [file normalize [path_sanitize $chapter_name]]
	if {[file exists $outdir]} {
		if {![is_dir_empty $outdir]} {
			continue
		}
	} else {
		file mkdir $outdir
	}
	cd $outdir
	incr count
	puts "\[$count/$total\] Downloading $chapter_name..."
	if {[catch {chapter_dl $chapter_id} err]} {
		puts "Failure to download $chapter_name!\n\n$err"
		file delete -force -- $outdir
	}
	cd $orig_pwd
}

if {$covers} {
	puts "Downloading serie covers JSON..."
	if {[catch {api_dl covers $serie_id} json]} {
		die "Failure to download serie covers JSON!\n\n$err"
	}
	set root [json::json2dict $json]
	set covers [dict get $root covers]
	if {$covers eq ""} {
		return
	}
	curl --remote-name-all $URL_BASE\{[join $covers ,]\}
	foreach cover [lmap x $covers {file tail $x}] {
		regexp {\d+v([\d.]+)\.(jpe?g|png)$} $cover -> volume extension
		if {[string is entier $volume]} {
			set volume [format %02d $volume]
		} elseif {[string is double $volume]} {
			set volume [format %04.1f $volume]
		}
		file rename $cover \
			[path_sanitize "$serie_title - c000 (v$volume) - Cover.$extension"]
	}
}
