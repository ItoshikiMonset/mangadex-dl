#!/usr/bin/env tclsh
set scriptdir [file dirname [file dirname \
							 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]
source [file join $scriptdir mangadex_util.tcl]
source [file join $scriptdir atom.tcl]

if {![executable_check curl]} {
	die "curl executable not found"
}


proc tstamp_sort {c1 c2} {
	expr [dict get $c1 timestamp] - [dict get $c2 timestamp]
}


# Option and argument handling
autocli usage opts \
	[file tail [info script]] \
	"monitor Mangadex series" \
	"\[OPTIONS\] CATALOG" \
	{
		"Read series to monitor from a catalog using the following syntax:"
		"    {serie_url ?\"autodl\" 1? ?\"group_filter\" group_name?}..."
		""
		"For each serie, an ATOM feed is created next to the given CATALOG"
		"file and is updated for each new chapter."
		"A database holding the last timestamp for the catalog is also"
		"created at the same place."
		""
		"If autodl is set, new chapters for this serie are downloaded to the"
		"directory specified via the -autodl-dir option."
		"If group_filter is set to GROUP, only chapters having it as one of"
		"their group are downloaded. Even if chapers isn't downloaded because"
		"of group_filter, the feed is still updated."
	} \
	{
		proxy      {param ""   PROXY_URL "Set the curl HTTP/HTTPS proxy."}
		lang       {param "gb" LANG_CODE "Only monitor chapters in this language."}
		autodl-dir {param "."  DIRECTORY "Where to auto download new chapters."}
	}
dictassign $opts

if {$argc < 1} {
	die $usage
}
shift catalog_path

if {$proxy ne ""} {
	set ::env(http_proxy)  $proxy
	set ::env(https_proxy) $proxy
}


# Various path setting and init file reading
set catalog [read_file $catalog_path]
if {![string is list $catalog]} {
	die "$catalog_path: does not contain a Tcl list"
}

set datadir_path [file normalize [file dirname $catalog_path]]

set tstampdb_path [file join $datadir_path timestamp.db]
if {[file exists $tstampdb_path]} {
	set tstampdb [read_file $tstampdb_path]
	if {![string is list $tstampdb] || [llength $tstampdb] % 2} {
		die "$tstampdb_path: does not contain a Tcl dict"
	}
} else {
	set tstampdb {}
}

# Loop over the catalog entries of the form:
#   url ?"autodl" 1? ?"group_filter" group?
set orig_pwd [pwd]
foreach entry $catalog {
	if {![string is list $entry] || [llength $entry] == 0} {
		puts stderr "$entry: not a valid catalog entry"
		continue
	}

	# Download serie JSON
	set serie_url [lindex $entry 0]
	if {![regexp {https://mangadex\.org/title/(\d+)/[^/]+} $serie_url -> serie_id]} {
		puts stderr "$serie_url: invalid mangadex URL"
		continue
	}
	puts "Downloading serie JSON ($serie_url)..."
	set root [json_dl https://mangadex.org/api/manga/$serie_id]
	set chapters [dict get $root chapter]
	# Filter chapters by language
	if {$lang ne ""} {
		set chapters [dict filter $chapters script {key val} \
						  {string equal [dict get $val lang_code] $lang}]
	}
	# Sort chapters by their timestamp (oldest first)
	set chapters [lsort -stride 2 -index 1 -command tstamp_sort $chapters]
	if {[llength $chapters] == 0} {
		puts stderr "$serie_url: no chapter found"
		continue
	}

	# Compare local and remote timestamp and filter chapters to only keep
	# the new ones; if new chapters there are
	set no_local_tstamp [catch {dict get $tstampdb $serie_id} local_tstamp]
	set remote_tstamp [dict get [lindex $chapters end] timestamp]
	dict set tstampdb $serie_id $remote_tstamp

	if {$no_local_tstamp || $local_tstamp == $remote_tstamp} {
		continue
	}
	set chapters [dict filter $chapters script {key val} \
					  {expr {[dict get $val timestamp] > $local_tstamp}}]

	# Handle extra entry arguments
	set autodl 0
	set group_filter ""
	if {[llength $entry] > 1} {
		set extra_args [lrange $entry 1 end]
		dict get? $extra_args autodl autodl
		dict get? $extra_args group_filter group_filter
	}

	# Read feed or create it if it doesn't exist
	set serie_title [dict get $root manga title]
	set feed_path [file join $datadir_path \
				   [path_sanitize ${serie_title}_${serie_id}].xml]
	set feed_title "$serie_title - new Mangadex chapters"
	if {![file exists $feed_path]} {
		set feed [atom create $feed_path $feed_title]
	} else {
		set feed [atom read $feed_path]
	}

	# Loop over every new chapter, append to feed and download if autodl is set
	# and group_filter matches at least one group
	foreach {chapter_id chapter_data} $chapters {
		set chapter_name [chapter_format_name $serie_title $chapter_data]
		if {$autodl && ($group_filter eq "" || \
						[dict get $chapter_data group_name] eq $group_filter   ||
						[dict get $chapter_data group_name_2] eq $group_filter ||
						[dict get $chapter_data group_name_3] eq $group_filter)} {
			set outdir [file join $autodl_dir [path_sanitize $chapter_name]]
			file mkdir $outdir
			cd $outdir
			puts "Downloading $chapter_name..."
			chapter_dl $chapter_id
			cd $orig_pwd
			atom add_entry feed "$chapter_name" "Downloaded to $outdir"
		} else {
			atom add_entry feed "$chapter_name"
		}
	}
	atom write $feed
}
write_file $tstampdb_path $tstampdb
