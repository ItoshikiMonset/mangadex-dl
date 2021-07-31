#!/usr/bin/env tclsh
# TODO: check when chapter is last (how?) and put it in Atom
set scriptdir [file dirname [file dirname \
								 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]
source [file join $scriptdir mdex_util.tcl]
source [file join $scriptdir atom.tcl]
util::exec_require curl


# proc remove_comments str {regsub -all {#[^\n]*\n?} $str {}}

proc tstamp_compare {c1 c2} {- [get_chapter_tstamp $c1] [get_chapter_tstamp $c2]}


# Option and argument handling
set optres [util::autocli \
	{
		proxy       {param "" PROXY_URL {Set the curl HTTP/HTTPS proxy.}}
		lang        {param en LANG_CODE {Only monitor new chapters in this language.}}
		autodl      {flag               {Set the "autodl" option for every catalog item.}}
		autodl-dir  {param "" DIRECTORY {Where to auto download new chapters.} \
						                {Defaults to the same directory as __CATALOG__.}}
		feed-dir    {param "" DIRECTORY {Where to store the chapter update feeds.} \
						                {Defaults to the same directory as __CATALOG__.}}
		single-feed {flag               {Produce a single feed instead of one per manga.}}
	} \
	[file tail [info script]] \
	{monitor MangaDex manga updates} \
	CATALOG \
	{
		{Read mangas to monitor from __CATALOG__, a file using the following syntax:}
		{    CATALOG = ITEM ITEM...}
		{    ITEM = MANGA_ID | "{" MANGA_ID OPTION VALUE OPTION VALUE... "}"}
		{}
		{Comments are everything from a "#" to a newline or end of file.}
		{Since this is actually a literal Tcl list, all the spaces used in these syntax rules are
		 runs of one or more whitespace characters ([[:space:]]+ in POSIX EREs).}
		{}
		{The following item OPTIONs are available:}
		{    autodl}
		{        If VALUE is 1, new chapters for this manga are downloaded to the directory
			     specified via the -autodl-dir option. If the -autodl option is set, using a value
			     of 0 disables it.}
		{}
		{    group}
		{        Only download chapters having VALUE matching one of their group names.}
		{}
		{    title}
		{        Use VALUE as title instead of the MangaDex provided one.}
		{}
		{For each list item:}
		{    If this is the first run since it was added to the __CATALOG__, nothing is done except
			 for the creation of its (empty) Atom feed in the same directory as the __CATALOG__.}
		{}
		{    Else, MangaDex is queried to find if there are new chapters since the last run. If this
			 is the case, its Atom feed is updated with and those chapters are downloaded if autodl
			 is currently enabled.}
		{}
		{A database holding the last chapter timestamp for each item is also maintained in that same
		 directory.}
	}]

if {![util::shift catalog_path] || $argc != 0} {
	util::usage stderr 1
}

dict assign $optres
if {$proxy ne ""} {
	set ::env(http_proxy)  $proxy
	set ::env(https_proxy) $proxy
}
set autodl_default $autodl
unset autodl


set catalog [remove_comments [util::read_wrap $catalog_path]]
if {![string is list $catalog]} {
	util::die "$catalog_path: does not contain a Tcl list"
}

set datadir_path [file dirname $catalog_path]

set tstampdb_path [file join $datadir_path timestamps.tcldict]
if {[file exists $tstampdb_path]} {
	set tstampdb [util::read_wrap $tstampdb_path]
	if {![util::is_dict $tstampdb]} {
		util::die "$tstampdb_path: does not contain a Tcl dict"
	}
} else {
	set tstampdb [dict create]
}
util::atexit add {
	global tstampdb_path tstampdb
	util::write_wrap $tstampdb_path $tstampdb
}

if {$autodl_dir eq ""} {
	set autodl_dir $datadir_path
}
if {![file isdirectory $autodl_dir]} {
	util::die "$autodl_dir: directory not found"
} elseif {![file writable $autodl_dir] || ![file executable $autodl_dir]} {
	util::die "$autodl_dir: permission to access or write denied"
}

if {$feed_dir eq ""} {
	set feed_dir $datadir_path
}
if {![file isdirectory $feed_dir]} {
	util::die "$feed_dir: directory not found"
} elseif {![file writable $feed_dir] || ![file executable $feed_dir]} {
	util::die "$feed_dir: permission to access or write denied"
}

if {$single_feed} {
	set feed_path [file join $feed_dir mangadex.xml]
	set feed [atom read_or_create $feed_path "new MangaDex chapters"]
	util::atexit add {
		global feed
		atom write $feed
	}
}

# Loop over the catalog entries
foreach entry $catalog {
	if {![string is list $entry] || [llength $entry] == 0} {
		puts stderr "$entry: not a valid catalog entry"
		continue
	}

	# Download manga JSON
	util::lshift entry manga_id
	util::puts_attr stderr {{bold on}} \
		"\[[incr entry_count]/[llength $catalog]\] Processing manga $manga_id..."

	if {[catch {get_chapter_list $manga_id $lang} chapters]} {
		puts stderr "Failed to download chapter list JSON!\n\n$chapters"
		continue
	}

	# Parse the entry extra options
	set autodl $autodl_default
	set group_filter ""
	set manga_title [get_rel_title [dict get [lindex $chapters 0] relationships] $lang]
	if {[llength $entry] != 0} {
		dict get? $entry autodl autodl
		dict get? $entry group_filter group
		dict get? $entry manga_title title
	}

	# Read feed or create per manga feed
	if {!$single_feed} {
		set feed_path [file join $feed_dir [util::path_sanitize ${manga_title}_${manga_id}].xml]
		set feed [atom read_or_create $feed_path "$manga_title - new MangaDex chapters"]
	}

	# Sort chapters by their timestamp (oldest first)
	set chapters [lsort -command tstamp_compare $chapters]

	# Compare local with remote timestamp
	set no_local_tstamp [! [dict get? $tstampdb local_tstamp $manga_id]]
	set remote_tstamp [get_chapter_tstamp [lindex $chapters end]]
	dict set tstampdb $manga_id $remote_tstamp

	if {$no_local_tstamp || $local_tstamp == $remote_tstamp} {
		puts stderr "No new chapters"
		after 500; # Sleep to avoid hitting the rate limit of 5 req/s
		continue
	}
	# Filter chapters to keep only the new ones
	set chapters [util::lfilter ch $chapters {[get_chapter_tstamp $ch] > $local_tstamp}]

	# Loop over every new chapter, append to feed and download if autodl is set
	# and group matches at least one group_name
	set ch_count 0
	foreach ch $chapters {
		set ch_dirname [chapter_dirname $ch $lang $manga_title]
		set group_names [get_rel_groups [dict get $ch relationships]]
		if {$autodl && ($group_filter eq "" || $group_filter in $group_names)} {
			set outdir [file join $autodl_dir [util::path_sanitize $ch_dirname]]
			if {[file exists $outdir] && ![util::is_dir_empty $outdir]} {
				puts stderr "$outdir: directory exists and isn't empty"
				continue
			}
			file mkdir $outdir
			set atom_link $URL_BASE/chapter/[dict get $ch data id]
			puts stderr "\[[incr ch_count]/[llength $chapters]\] Downloading $ch_dirname..."
			if {[catch {dl_chapter $ch $outdir} err]} {
				puts stderr "Failed to download $outdir!\n\n$err"
				atom add_entry feed "(Fail) $ch_dirname" content "Download failure" link $atom_link
				file delete -force -- $outdir
			} else {
				atom add_entry feed "$ch_dirname" content "Downloaded to $outdir" link $atom_link
			}
		} else {
			atom add_entry feed "$ch_dirname"
		}
	}
	if {!$single_feed} {
		atom write $feed
	}
}
