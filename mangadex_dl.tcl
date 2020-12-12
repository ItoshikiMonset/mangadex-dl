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

puts "Downloading serie JSON ($serie_url)..."
if {[catch {api_dl manga $serie_id chapters} json]} {
	puts stderr "Failed to download serie JSON!\n\n$json"
	exit 1
}
if {[catch {json::json2dict $json} root]} {
	puts stderr "Invalid serie JSON or curl uncatched error!\n\n$root"
	exit 1
}
dict assign $root
dict assign $data
if {$code != 200} {
	puts stderr "Code $code (status: $status) received"
	exit 1
}

# Filter chapters by language then number arguments if required
if {$lang ne ""} {
	set chapters [lfilter ch $chapters {[dict get $ch language] eq $lang}]
}

if {$argc >= 1} {
	set chapters [lfilter ch $chapters {[dict get $ch chapter] in $argv}]
}

# Iterate over the filtered chapters and download
set total [llength $chapters]
set orig_pwd [pwd]
set serie_title [dict get [lindex $chapters 0] mangaTitle]

set group_dict [dict create]
foreach group $groups {
	dict set group_dict [dict get $group id] [dict get $group name]
}

foreach ch [lreverse $chapters] {
	set ch_group_names \
		[lmap ch_gid [dict get $ch groups] {dict get $group_dict $ch_gid}]
	set ch_caption [chapter_caption $serie_title $ch $ch_group_names]
	set outdir [file normalize [path_sanitize $ch_caption]]
	if {[file exists $outdir]} {
		if {![is_dir_empty $outdir]} {
			continue
		}
	} else {
		file mkdir $outdir
	}
	cd $outdir
	incr count
	puts "\[$count/$total\] Downloading $ch_caption..."
	if {[catch {chapter_dl [dict get $ch id]} err]} {
		puts stderr "Failed to download $ch_caption!\n\n$err"
		file delete -force -- $outdir
	}
	cd $orig_pwd
}

if {$covers} {
	puts "Downloading serie covers JSON..."
	if {[catch {api_dl manga $serie_id covers} json]} {
		die "Failed to download serie covers JSON!\n\n$json"
	}
	if {[catch {json::json2dict $json} root]} {
		puts stderr "Invalid serie JSON or curl uncatched error!\n\n$root"
		exit 1
	}
	dict assign $root

	if {$code != 200} {
		puts stderr "Code $code (status: $status) received"
		exit 1
	}

	if {[llength $data] == 0} {
		puts stderr "No cover to be found"
		return
	}
	foreach cov $data {
		dict assign $cov
		regexp {\.([a-z]+)\?\d+$} $url -> ext
		if {[string is entier $volume]} {
			set volume [format %02d $volume]
		} elseif {[string is double $volume]} {
			set volume [format %04.1f $volume]
		}

		lappend urls $url
		lappend outnames \
			[path_sanitize "$serie_title - c000 (v$volume) - Cover.$ext"]
	}
	curl_map $urls $outnames
}
