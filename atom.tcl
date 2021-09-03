# Simple Atom reading/writing, exported procs:
#	  create, read, add_entry, write
package require tdom
set scriptdir [file dirname [file dirname \
							 [file normalize [file join [info script] dummy]]]]
if {![namespace exists util]} {
	source [file join $scriptdir util.tcl]
}


namespace eval atom {
	namespace import ::util::?
	namespace export create read read_or_create add_entry write
	namespace ensemble create

	variable xmlns http://www.w3.org/2005/Atom


	proc timestamp {} {
		clock format [clock seconds] -format %Y-%m-%dT%XZ -timezone :UTC
	}

	# nodespec: {tag ?text? ?attrname attrval...?}
	# Use {tag {} attrname attrval...} if you want an attribute but no text
	proc node {doc nodespec} {
		variable xmlns

		set attrs [lassign $nodespec tag text]
		set node [$doc createElementNS $xmlns $tag]
		if {$text ne ""} {
			$node appendChild [$doc createTextNode $text]
		}
		if {$attrs ne ""} {
			$node setAttribute {*}$attrs
		}
		return $node
	}

	# args: node's nodespec arguments
	proc add {doc node args} {
		$node appendChild [node $doc $args]
	}

	# Wrapper around domNode selectNodes
	proc select_nodes {doc args} {
		variable xmlns
		[$doc documentElement] selectNodes -namespaces [list atom $xmlns] \
			{*}$args
	}

	# Ignore id for local feeds (a file:// URI will be used)
	proc create {path title {id {}}} {
		variable xmlns

		set path [file normalize $path]
		set atom [dict create path $path entry_count 0 modified 1]
		set doc [dom createDocumentNS $xmlns feed]
		dict set atom xml $doc
		set root [$doc documentElement]
		add $doc $root title $title
		add $doc $root id [? {$id ne ""} {$id} {file://$path}]
		add $doc $root updated [timestamp]
		return $atom
	}

	proc read {path} {
		set atom [dict create path [file normalize $path] modified 0]
		set doc [dom parse [util::read_wrap $path]]
		dict set atom xml $doc
		dict set atom entry_count [llength [select_nodes $doc //atom:entry]]
		return $atom
	}

	proc read_or_create {path title} {
		if {[file exists $path]} {
			read $path
		} else {
			set ret [create $path $title]
			atom write $ret
			return $ret
		}
	}

	proc write {atom} {
		if {[dict get $atom modified]} {
			util::write_wrap [dict get $atom path] [[dict get $atom xml] asXML -indent 2]
		}
	}

	# Add an entry to the feed in the _atom variable
	# args is a dictionary containing the optional values for keys id, content
	# and link; no id means local feed, thus a unique URI based on feed path
	# and entry count will be used
	proc add_entry {_atom title args} {
		upvar $_atom atom

		set doc [dict get $atom xml]
		if {![dict get? $args id id]} {
			set id file://[dict get $atom path]#[dict get $atom entry_count]
		}
		set timestamp [timestamp]

		set entry [node $doc entry]
		add $doc $entry title $title
		add $doc $entry id $id
		add $doc $entry updated $timestamp
		if {[dict get? $args content content]} {
			add $doc $entry content $content type html
		}
		if {[dict get? $args link link]} {
			add $doc $entry link {} href $link
		}

		[$doc documentElement] appendChild $entry
		dict incr atom entry_count
		dict set atom modified 1
		[select_nodes $doc //atom:feed/atom:updated/text()] nodeValue $timestamp
	}
}
