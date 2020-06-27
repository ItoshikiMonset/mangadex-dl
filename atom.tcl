# Simple Atom reading/writing, exported functions:
#     create, read, add_entry, write
package require tdom
set scriptdir [file dirname [file dirname \
							 [file normalize [file join [info script] dummy]]]]
source [file join $scriptdir util.tcl]


namespace eval atom {
	variable xmlns http://www.w3.org/2005/Atom

	proc timestamp {} {
		clock format [clock seconds] -format %Y-%m-%dT%XZ -timezone :UTC
	}

	# nodespec: {tag ?text? ?attrname attrval...?}
	# Use {tag {} attrname attrval...} if you want an attribute but no text
	proc node {doc nodespec} {
		variable xmlns

		lassign $nodespec tag text attr
		set node [$doc createElementNS $xmlns $tag]
		if {$text ne ""} {
			$node appendChild [$doc createTextNode $text]
		}
		if {[llength $nodespec] > 2} {
			$node setAttribute {*}[lrange $nodespec 2 end]
		}
		return $node
	}

	proc add {doc node nodespec} {
		$node appendChild [node $doc $nodespec]
	}

	proc root_add {doc nodespec} {
		add $doc [$doc documentElement] $nodespec
	}

	proc select_nodes {doc args} {
		variable xmlns
		[$doc documentElement] selectNodes -namespaces [list atom $xmlns] {*}$args
	}

	proc create {path title} {
		variable xmlns

		set path [file normalize $path]
		set atom [dict create path $path entry_count 0 modified 1]
		set doc [dom createDocumentNS $xmlns feed]
		dict set atom xml $doc
		root_add $doc [list title $title]
		root_add $doc [list id "file://$path"]
		root_add $doc [list updated [timestamp]]
		return $atom
	}

	proc read {path} {
		set atom [dict create path [file normalize $path] modified 0]
		set doc [dom parse [read_file $path]]
		dict set atom xml $doc
		dict set atom entry_count [llength [select_nodes $doc //atom:entry]]
		return $atom
	}

	proc write {atom} {
		if {[dict get $atom modified] == 1} {
			write_file [dict get $atom path] [[dict get $atom xml] asXML -indent 2]
		}
	}

	proc add_entry {_atom title {content {}} {link {}}} {
		upvar $_atom atom

		set doc [dict get $atom xml]
		set root [$doc documentElement]
		set id "file://[dict get $atom path]#[dict get $atom entry_count]"
		set timestamp [timestamp]

		set entry [node $doc entry]
		add $doc $entry [list title $title]
		add $doc $entry [list id $id]
		add $doc $entry [list updated $timestamp]
		if {$content ne ""} {
			add $doc $entry [list content $content]
		}
		if {$link ne ""} {
			add $doc $entry [list link {} href $link]
		}

		$root appendChild $entry

		dict incr atom entry_count
		dict set atom modified 1
		[select_nodes $doc //atom:feed/atom:updated/text()] nodeValue $timestamp
	}

	namespace export create read add_entry write
	namespace ensemble create
}
