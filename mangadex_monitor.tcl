#!/usr/bin/env tclsh
# TODO: download all series with one curl invocation (so we get pipelining) and use ::json::many-json2dict
set scriptdir [file dirname [file dirname \
							 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]
source [file join $scriptdir mangadex_util.tcl]
source [file join $scriptdir atom.tcl]

if {![executable_check curl]} {
	die "curl executable not found"
}


proc remove_comments str {
	regsub -all {#[^\n]*\n} $str {}
}

proc tstamp_sort {c1 c2} {
	- [dict get $c1 timestamp] [dict get $c2 timestamp]
}


# Option and argument handling
autocli usage opts \
	[file tail [info script]] \
	"monitor Mangadex series" \
	"\[OPTIONS\] CATALOG" \
	{
		"Read series to monitor from CATALOG, a file containing a Tcl list"
		"using the following syntax:"
		"    {SERIE_URL ?OPTION VALUE? ...} ..."
		"Everything between a # and a newline is ignored."
		""
		"with the following OPTIONs available:"
		"    autodl"
		"        If VALUE is 1, new chapters for this serie are downloaded to "
		"        the directory specified via the -autodl-dir option. If the"
		"        -autodl option is set, using a value of 0 disables it."
		""
		"    group"
		"        Only download chapters having VALUE matching one of their"
		"        group names."
		""
		"    title"
		"        Use VALUE as title instead of the Mangadex provided one."
		""
		"For each serie, an Atom feed is created next to the given CATALOG"
		"file and updated for each new chapter."
		"A database holding the last timestamp for each catalog entry is also"
		"created at the same place."
	} \
	{
		proxy       {param ""   PROXY_URL "Set the curl HTTP/HTTPS proxy."}
		lang        {param "gb" LANG_CODE "Only monitor chapters in this language."}
		autodl      {flag                 "Set the \"autodl\" option for every serie."}
		autodl-dir  {param ""   DIRECTORY "Where to auto download new chapters." \
						                  "Defaults to the same directory as CATALOG."}
		single-feed {flag                 "Use a single feed instead of one per serie."}
	}

if {$argc < 1} {
	die $usage
}
shift catalog_path

dict assign $opts
if {$proxy ne ""} {
	set ::env(http_proxy)  $proxy
	set ::env(https_proxy) $proxy
}
set autodl_default $autodl
unset autodl


set catalog [remove_comments [read_file $catalog_path]]
if {![string is list $catalog]} {
	die "$catalog_path: does not contain a Tcl list"
}

set datadir_path [file normalize [file dirname $catalog_path]]

set tstampdb_path [file join $datadir_path timestamps.tcldict]
if {[file exists $tstampdb_path]} {
	set tstampdb [read_file $tstampdb_path]
	if {![string is list $tstampdb] || [llength $tstampdb] % 2} {
		die "$tstampdb_path: does not contain a Tcl dict"
	}
} else {
	set tstampdb [dict create]
}

if {$single_feed} {
	set feed_path [file join $datadir_path mangadex.xml]
	set feed [atom read_or_create $feed_path "new Mangadex chapters"]
}

if {$autodl_dir eq ""} {
	set autodl_dir $datadir_path
} elseif {![file isdirectory $autodl_dir]} {
	die "$autodl_dir: directory not found"
} elseif {![file writeable $autodl_dir] || ![file executable $autodl_dir]} {
	die "$autodl_dir: permission to access or write denied"
}


# Loop over the catalog entries
set orig_pwd [pwd]
set epoch [clock seconds]
foreach entry $catalog {
	if {![string is list $entry] || [llength $entry] == 0} {
		puts stderr "$entry: not a valid catalog entry"
		continue
	}

	# Download serie JSON
	set entry [lassign $entry serie_url]
	if {![regexp {https://(?:www\.)?mangadex\.org/title/(\d+)/[^/]+} $serie_url -> serie_id]} {
		puts stderr "$serie_url: invalid mangadex URL"
		continue
	}
	puts "Downloading serie JSON ($serie_url)..."
	if {[catch {api_dl manga $serie_id chapters} json]} {
		puts stderr "Failed to download serie JSON!\n\n$json"
		continue
	}
	if {[catch {json::json2dict $json} root]} {
		puts stderr "Invalid serie JSON or curl uncatched error!\n\n$root"
		continue
	}
	dict assign $root
	dict assign $data
	if {$code != 200} {
		puts stderr "Code $code (status: $status) received"
		continue
	}

	# Parse the entry extra options
	set autodl $autodl_default
	set group_filter ""
	set serie_title [dict get [lindex $chapters 0] mangaTitle]
	if {[llength $entry] != 0} {
		dict get? $entry autodl autodl
		dict get? $entry group_filter group
		dict get? $entry serie_title title
	}

	# Read feed or create per serie feed
	if {!$single_feed} {
		set feed_path [file join $datadir_path \
						   [path_sanitize ${serie_title}_${serie_id}].xml]
		set feed [atom read_or_create $feed_path \
					  "$serie_title - new Mangadex chapters"]
	}

	# Filter chapters by language
	if {$lang ne ""} {
		set chapters [lfilter ch $chapters {[dict get $ch language] eq $lang}]
	}

	# Ignore chapters not yet released
	set chapters [lfilter ch $chapters {[dict get $ch timestamp] < $epoch}]
	if {[llength $chapters] == 0} {
		puts stderr "$serie_url: no chapter found"
		continue
	}
	# Sort chapters by their timestamp (oldest first)
	set chapters [lsort -command tstamp_sort $chapters]

	# Compare local with remote timestamp and filter chapters to only keep
	# the new ones; if new chapters there are
	set no_local_tstamp [catch {dict get $tstampdb $serie_id} local_tstamp]
	set remote_tstamp [dict get [lindex $chapters end] timestamp]
	dict set tstampdb $serie_id $remote_tstamp

	if {$no_local_tstamp || $local_tstamp == $remote_tstamp} {
		continue
	}
	set chapters [lfilter ch $chapters \
					  {[dict get $ch timestamp] > $local_tstamp}]

	# Convert group array of dicts to id: name dict
	set group_dict [dict create]
	foreach group $groups {
		dict set group_dict [dict get $group id] [dict get $group name]
	}

	# Loop over every new chapter, append to feed and download if autodl is set
	# and group matches at least one group_name
	foreach ch $chapters {
		set ch_group_names \
			[lmap ch_gid [dict get $ch groups] {dict get $group_dict $ch_gid}]
		set ch_caption [chapter_caption $serie_title $ch $ch_group_names]
		if {$autodl && ($group_filter eq "" || $group_filter in $ch_group_names)} {
			set outdir [file normalize \
							[file join $autodl_dir [path_sanitize $ch_caption]]]
			file mkdir $outdir
			cd $outdir
			set chapter_id [dict get $ch id]
			set link $URL_BASE/chapter/$chapter_id
			puts "Downloading $ch_caption..."
			if {[catch {chapter_dl $chapter_id} err]} {
				atom add_entry feed "(Fail) $ch_caption" "Download failure" $link
				file delete -force -- $outdir
			} else {
				atom add_entry feed "$ch_caption" "Downloaded to $outdir" $link
			}
			cd $orig_pwd
		} else {
			atom add_entry feed "$ch_caption"
		}
	}
	if {!$single_feed} {
		atom write $feed
	}
}
if {$single_feed} {
	atom write $feed
}
write_file $tstampdb_path $tstampdb
