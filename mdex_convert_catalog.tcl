#!/usr/bin/env tclsh
set scriptdir [file dirname [file dirname \
								 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]
source [file join $scriptdir mdex_util.tcl]
package require json::write
util::exec_require curl


proc remove_comments str {regsub -all {#[^\n]*\n} $str {}}


# Option and argument handling
set optres [util::autocli \
	{
		proxy  {param {}   PROXY_URL {Set the curl HTTP/HTTPS proxy.}}
	} \
	[file tail [info script]] \
	{update monitor config files for new MangaDex API} \
	{CATALOG_PATH} \
	{
		{Convert the catalog found at CATALOG_PATH along with its corresponding timestamp database
		 to work with the new MangaDex API.}
		{Before that, the old versions are backuped to .old suffixed files.}
	}]

if {![util::shift catalog_path] || $argc != 0} {
	util::die [util::usage]
}

dict assign $optres
if {$proxy ne ""} {
	set ::env(http_proxy)  $proxy
	set ::env(https_proxy) $proxy
}


set tstampdb_path [file join [file dirname $catalog_path] timestamps.tcldict]
if {[file exists ${catalog_path}.old]} {
	util::die "${catalog_path}.old: file already exists"
}
if {[file exists ${tstampdb_path}.old]} {
	util::die "${tstampdb_path}.old: file already exists"
}

set catalog [remove_comments [util::read_wrap $catalog_path]]
if {![string is list $catalog]} {
	util::die "$catalog_path: does not contain a Tcl list"
}

set legacy_ids [lmap x $catalog {manga_url_to_id [lindex $x 0] legacy}]
set post_data [::json::write object \
				   type [::json::write string manga] \
				   ids  [::json::write array {*}$legacy_ids] \
			  ]
foreach obj [json::json2dict [api_post_json legacy/mapping $post_data]] {
	if {[dict get $obj result] ne "ok"} {
		puts stderr [dict get $obj error]
		continue
	}
	dict set idmap [dict get $obj data attributes legacyId] [dict get $obj data attributes newId]
}

file rename -- $catalog_path ${catalog_path}.old
set chan [open $catalog_path {WRONLY CREAT EXCL}]
foreach entry $catalog legacy_id $legacy_ids {
	if {[dict exists $idmap $legacy_id]} {
		puts -nonewline $chan [list [lreplace $entry 0 0 [dict get $idmap $legacy_id]]]
		if {![dict exists [lrange $entry 1 end] title]} {
			set tail [regexp -inline {[^/]+$} [lindex $entry 0]]
			puts -nonewline $chan "  # [string totitle [string map {- " "} $tail]]"
		}
		puts $chan ""
	}
}
close $chan

if {![file exists $tstampdb_path]} {
	exit
}
set tstampdb [util::read_wrap $tstampdb_path]
if {! [util::is_dict $tstampdb]} {
	util::die "$tstampdb_path: does not contain a Tcl dict"
}
file rename -- $tstampdb_path ${tstampdb_path}.old
set chan [open $tstampdb_path {WRONLY CREAT EXCL}]
puts $chan [dict map {legacy_id tstamp} $tstampdb {
	if {![dict exists $idmap $legacy_id]} { # Garbage collect old ids while at it
		continue
	}
	set legacy_id [dict get $idmap $legacy_id]
	set tstamp
}]
close $chan
