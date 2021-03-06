#!/usr/bin/perl -w
#
# msgconvert.pl:
#
# Convert .MSG files (made by Outlook (Express)) to multipart MIME messages.
#
# Copyright 2002, 2004, 2006 Matijs van Zuijlen
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation; either version 2 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
# Public License for more details.
#
# CHANGES:
# 20020715  Recognize new items 'Cc', mime type of attachment, long
#	    filename of attachment, and full headers. Attachments turn out
#	    to be numbered, so a regexp is now used to recognize label of
#	    items that are attachments.
# 20020831  long file name will definitely be used if present. Full headers
#	    and mime type information are used when present. Created
#	    generic system for specifying known items to be skipped.
#	    Unexpected contents is never reason to bail out anymore. Added
#	    support for usage message and option processing (--verbose).
# 20040104  Handle address data slightly better, make From line less fake,
#	    make $verbose and $skippable_entries global vars, handle HTML
#	    variant of body text if present (though not optimally).
# 20040214  Fix typos and incorrect comments.
# 20040307  - Complete rewrite: All functional parts are now in the package
#	      MSGParser;
#	    - Creation of MIME::Entity object is delayed until the output
#	      routines, which means all data is known; This means I can
#	      create a multipart/alternative body.
#	    - Item names are parsed (thanks to bfrederi@alumni.sfu.ca for
#	      the information).
# 20040514  Check if $self->{HEAD} actually exists before trying to add its
#	    contents to the output Mime object's header data.
#	    (Bug reported by Thomas Ng).
#	    Don't produce multipart messages if not needed.
#	    (Bug reported by Justin B. Scout).
# 20040529  Correctly format OLEDATE.
# 20040530  - Extract date from property 0047 (thanks, Marc Goodman).
#	    - Use address data to make To: and Cc: lines complete
#	    - Use the in-reply-to property
#	    - More unknown properties named.
#	    - Found another property containing an SMTP address.
#	    - Put non-SMTP type addresses back in output.
# 20040825  Replace 'our' to declare globals with 'use vars'. This means
#	    the globals our now properly scoped inside the package and not
#	    the file.
#	    This also fixes the bug that this program did not work on perl
#	    versions below 5.6. (Bug reported by Tim Gustafson)
# 20060218  More sensible encoding warnings.
# 20060219  Move OLE parsing to main program.
#           Parse nested MSG files (Bug reported by Christof Lukas).
# 20060225  Simplify code.
#

#
# Import modules.
#
package MSGParser;
use strict;
use OLE::Storage_Lite;
use MIME::Entity;
use MIME::Parser;
use Date::Format;
use POSIX qw(mktime);
use constant DIR_TYPE => 1;
use constant FILE_TYPE => 2;

use vars qw($skipproperties $skipheaders);
#
# Descriptions partially based on mapitags.h
#
$skipproperties = {
  # Envelope properties
  '000B' => "Conversation key?",
  '001A' => "Type of message",
  '003B' => "Sender address variant",
  '003D' => "Contains 'Re: '",
  '003F' => "'recieved by' id",
  '0040' => "'recieved by' name",
  '0041' => "Sender variant address id",
  '0042' => "Sender variant name",
  '0043' => "'recieved representing' id",
  '0044' => "'recieved representing' name",
  '0046' => "Read receipt address id",
  '0051' => "'recieved by' search key",
  '0052' => "'recieved representing' search key",
  '0053' => "Read receipt search key",
  '0064' => "Sender variant address type",
  '0065' => "Sender variant address",
  '0070' => "Conversation topic",
  '0071' => "Conversation index",
  '0075' => "'recieved by' address type",
  '0076' => "'recieved by' email address",
  '0077' => "'recieved representing' address type",
  '0078' => "'recieved representing' email address",
  '007F' => "something like a message id",
  # Recipient properties
  '0C19' => "Reply address variant",
  '0C1D' => "Reply address variant",
  '0C1E' => "Reply address type",
  # Non-transmittable properties
  '0E02' => "?Should BCC be displayed",
  '0E0A' => "sent mail id",
  '0E1D' => "Subject w/o Re",
  '0E27' => "64 bytes: Unknown",
  '0FF6' => "Index",
  '0FF9' => "Index",
  '0FFF' => "Address variant",
  # Content properties
  '1008' => "Summary or something",
  '1009' => "RTF Compressed",
  # 'Common property'
  '3001' => "Display name",
  '3002' => "Address Type",
  '300B' => "'Search key'",
  # Attachment properties
  '3702' => "Attachment encoding",
  '3703' => "Attachment extension",
  '3709' => "'Attachment rendering'", # Maybe an icon or something?
  '3713' => "Icon URL?",
  # 'Mail user'
  '3A20' => "Address variant",
  # 3900 -- 39FF: 'Address book'
  '39FF' => "7 bit display name",
  # 'Display table properties'
  '3FF8' => "Routing data?",
  '3FF9' => "Routing data?",
  '3FFA' => "Routing data?",
  '3FFB' => "Routing data?",
  # 'Transport-defined envelope property'
  '4029' => "Sender variant address type",
  '402A' => "Sender variant address",
  '402B' => "Sender variant name",
  '5FF6' => "Recipient name",
  '5FF7' => "Recipient address variant",
  # 'Provider-defined internal non-transmittable property'
  '6740' => "Unknown, binary data",
  # User defined id's
  '8000' => "Content Class",
  '8002' => "Unknown, binary data",
};

$skipheaders = {
  "MIME-Version" => 1,
  "Content-Type" => 1,
  "Content-Transfer-Encoding" => 1,
  "X-Mailer" => 1,
  "X-Msgconvert" => 1,
  "X-MS-Tnef-Correlator" => 1,
  "X-MS-Has-Attach" => 1,
};

use constant ENCODING_UNICODE => '001F';
use constant KNOWN_ENCODINGS => {
    '000D' => 'Directory',
    '001F' => 'Unicode',
    '001E' => 'Ascii?',
    '0102' => 'Binary',
};

use constant MAP_ATTACHMENT_FILE => {
  '3701' => ["DATA",	    0], # Data
  '3704' => ["SHORTNAME",   1], # Short file name
  '3707' => ["LONGNAME",    1], # Long file name
  '370E' => ["MIMETYPE",    1], # mime type
  '3716' => ["DISPOSITION", 1], # disposition
};

use constant MAP_SUBITEM_FILE => {
  '1000' => ["BODY_PLAIN",	0], # Body
  '1013' => ["BODY_HTML",	0], # HTML Version of body
  '0037' => ["SUBJECT",		1], # Subject
  '0047' => ["SUBMISSION_ID",	1], # Seems to contain the date
  '007D' => ["HEAD",		1], # Full headers
  '0C1A' => ["FROM",		1], # Reply-To: Name
  '0C1E' => ["FROM_ADDR_TYPE",	1], # From: Address type
  '0C1F' => ["FROM_ADDR",	1], # Reply-To: Address
  '0E04' => ["TO",		1], # To: Names
  '0E03' => ["CC",		1], # Cc: Names
  '1035' => ["MESSAGEID",	1], # Message-Id
  '1042' => ["INREPLYTO",	1], # In reply to Message-Id
};

use constant MAP_ADDRESSITEM_FILE => {
  '3001' => ["NAME",		1], # Real name
  '3002' => ["TYPE",		1], # Address type
  '403D' => ["TYPE",		1], # Address type
  '3003' => ["ADDRESS",		1], # Address
  '403E' => ["ADDRESS",		1], # Address
  '39FE' => ["SMTPADDRESS",	1], # SMTP Address variant
};

#
# Main body of module
#

sub new {
  my $that = shift;
  my $class = ref $that || $that;

  my $self = {
    ATTACHMENTS => [],
    ADDRESSES => [],
    VERBOSE => 0,
    HAS_UNICODE => 0,
    FROM_ADDR_TYPE => "",
  };
  bless $self, $class;
}

#
# Main sub: parse the PPS tree, and return 
#
sub parse {
  my $self = shift;
  my $PPS = shift or die "Internal error: No PPS tree";
  $self->_RootDir($PPS);
}

sub mime_object {
  my $self = shift;

  my $bodymime;
  my $mime;

  if ($self->_IsMultiPart) {
    # Construct a multipart message object

    $mime = MIME::Entity->build(Type => "multipart/mixed");

    # Set the entity that we'll save the body parts to. If there's more than
    # one part, it's a new entity, otherwise, it's the main $mime object.
    if ($self->{BODY_HTML} and $self->{BODY_PLAIN}) {
      $bodymime = MIME::Entity->build(
	Type => "multipart/alternative",
	Encoding => "8bit",
      );
      $mime->add_part($bodymime);
    } else {
      $bodymime = $mime;
    }
    if ($self->{BODY_PLAIN}) {
      $self->_SaveAttachment($bodymime, {
	MIMETYPE => 'text/plain; charset=ISO-8859-1',
	ENCODING => '8bit',
	DATA => $self->{BODY_PLAIN},
	DISPOSITION => 'inline',
      });
    }
    if ($self->{BODY_HTML}) {
      $self->_SaveAttachment($bodymime, {
	MIMETYPE => 'text/html',
	ENCODING => '8bit',
	DATA => $self->{BODY_HTML},
	DISPOSITION => 'inline',
      });
    }
    foreach my $att (@{$self->{ATTACHMENTS}}) {
      $self->_SaveAttachment($mime, $att);
    }
  } elsif ($self->{BODY_PLAIN}) {
    # Construct a single part message object with a plain text body
    $mime = MIME::Entity->build(
      Type => "text/plain",
      Data => $self->{BODY_PLAIN}
    );
  } elsif ($self->{BODY_HTML}) {
    # Construct a single part message object with an HTML body
    $mime = MIME::Entity->build(
      Type => "text/html",
      Data => $self->{BODY_HTML}
    );
  }

  $self->_CopyHeaderData($mime);

  $self->_SetHeaderFields($mime);

  return $mime;
}

# Actually output the message in mbox format
sub print {
  my $self = shift;

  my $mime = $self->mime_object;

  # Construct From line from whatever we know.
  my $string = "";
  $string = (
    $self->{FROM_ADDR_TYPE} eq "SMTP" ?
    $self->{FROM_ADDR} :
    'someone@somewhere'
  );
  $string =~ s/\n//g;

  # The date used here is not really important.
  print "From ", $string, " ", scalar localtime, "\n";
  $mime->print(\*STDOUT);
  print "\n";
}

sub set_verbosity {
  my ($self, $verbosity) = @_;
  defined $verbosity or die "Internal error: no verbosity level";
  $self->{VERBOSE} = $verbosity;
}

#
# Below are functions that walk the PPS tree. The *Dir functions handle
# processing the directory nodes of the tree (mainly, iterating over the
# children), whereas the *Item functions handle processing the items in the
# directory (if such an item is itself a directory, it will in turn be
# processed by the relevant *Dir function).
#

#
# RootItem: Check Root Entry, parse sub-entries.
# The OLE file consists of a single entry called Root Entry, which has
# several children. These children are parsed in the sub SubItem.
# 
sub _RootDir {
  my ($self, $PPS) = @_;

  foreach my $child (@{$PPS->{Child}}) {
    $self->_SubItem($child);
  }
}

sub _SubItem {
  my ($self, $PPS) = @_;
  
  if ($PPS->{Type} == DIR_TYPE) {
    $self->_SubItemDir($PPS);
  } elsif ($PPS->{Type} == FILE_TYPE) {
    $self->_SubItemFile($PPS);
  } else {
    warn "Unknown entry type: $PPS->{Type}";
  }
}

sub _SubItemDir {
  my ($self, $PPS) = @_;

  $self->_GetOLEDate($PPS);

  my $name = $self->_GetName($PPS);

  if ($name =~ /__recip_version1 0_ /) { # Address of one recipient
    $self->_AddressDir($PPS);
  } elsif ($name =~ '__attach_version1 0_ ') { # Attachment
    $self->_AttachmentDir($PPS);
  } else {
    $self->_UnknownDir($self->_GetName($PPS));
  }
}

sub _SubItemFile {
  my ($self, $PPS) = @_;

  my $name = $self->_GetName($PPS);
  my ($property, $encoding) = $self->_ParseItemName($name);

  $self->_MapProperty($self, $PPS->{Data}, $property,
    MAP_SUBITEM_FILE) or $self->_UnknownFile($name);
}

sub _AddressDir {
  my ($self, $PPS) = @_;

  my $address = {
    NAME	=> undef,
    ADDRESS	=> undef,
    TYPE	=> "",
  };
  foreach my $child (@{$PPS->{Child}}) {
    $self->_AddressItem($child, $address);
  }
  push @{$self->{ADDRESSES}}, $address;
}

sub _AddressItem {
  my ($self, $PPS, $addr_info) = @_;

  my $name = $self->_GetName($PPS);

  # DIR Entries: There should be none.
  if ($PPS->{Type} == DIR_TYPE) {
    $self->_UnknownDir($name);
  } elsif ($PPS->{Type} == FILE_TYPE) {
    my ($property, $encoding) = $self->_ParseItemName($name);
    $self->_MapProperty($addr_info, $PPS->{Data}, $property,
      MAP_ADDRESSITEM_FILE) or $self->_UnknownFile($name);
  } else {
    warn "Unknown entry type: $PPS->{Type}";
  }
}

sub _AttachmentDir {
  my ($self, $PPS) = @_;

  my $attachment = {
    SHORTNAME	=> undef,
    LONGNAME	=> undef,
    MIMETYPE	=> 'application/octet-stream',
    ENCODING	=> 'base64',
    DISPOSITION	=> 'attachment',
    DATA	=> undef
  };
  foreach my $child (@{$PPS->{Child}}) {
    $self->_AttachmentItem($child, $attachment);
  }
  push @{$self->{ATTACHMENTS}}, $attachment;
}

sub _AttachmentItem {
  my ($self, $PPS, $att_info) = @_;

  my $name = $self->_GetName($PPS);

  my ($property, $encoding) = $self->_ParseItemName($name);

  if ($PPS->{Type} == DIR_TYPE) {

    if ($property eq '3701') {	# Nested MSG file
      my $msgp = new MSGParser();
      $msgp->parse($PPS);
      my $data = $msgp->mime_object->as_string;
      $att_info->{DATA} = $data;
      $att_info->{MIMETYPE} = 'message/rfc822';
      $att_info->{ENCODING} = '8bit';
    } else {
      $self->_UnknownDir($name);
    }

  } elsif ($PPS->{Type} == FILE_TYPE) {
    $self->_MapProperty($att_info, $PPS->{Data}, $property,
      MAP_ATTACHMENT_FILE) or $self->_UnknownFile($name);
  } else {
    warn "Unknown entry type: $PPS->{Type}";
  }
}

sub _MapProperty {
  my ($self, $hash, $data, $property, $map) = @_;

  defined $property or return 0;
  my $arr = $map->{$property} or return 0;

  $arr->[1] and $data =~ s/\000//g;
  $hash->{$arr->[0]} = $data;

  return 1;
}

sub _UnknownDir {
  my ($self, $name) = @_;

  if ($name eq '__nameid_version1 0') {
    $self->{VERBOSE}
      and warn "Skipping DIR entry $name (Introductory stuff)\n";
    return;
  }
  warn "Unknown DIR entry $name\n";
}

sub _UnknownFile {
  my ($self, $name) = @_;

  if ($name eq '__properties_version1 0') {
    $self->{VERBOSE}
      and warn "Skipping FILE entry $name (Properties)\n";
    return;
  }

  my ($property, $encoding) = $self->_ParseItemName($name);
  unless (defined $property) {
    warn "Unknown FILE entry $name\n";
    return;
  }
  if ($skipproperties->{$property}) {
    $self->{VERBOSE}
      and warn "Skipping property $property ($skipproperties->{$property})\n";
    return;
  } elsif ($property =~ /^80/) {
    $self->{VERBOSE}
      and warn "Skipping property $property (user-defined property)\n";
    return;
  } else {
    warn "Unknown property $property\n";
    return;
  }
}

#
# Helper functions
#

sub _GetName {
  my ($self, $PPS) = @_;
  return $self->_NormalizeWhiteSpace(OLE::Storage_Lite::Ucs2Asc($PPS->{Name}));
}

sub _NormalizeWhiteSpace {
  my ($self, $name) = @_;
  $name =~ s/\W/ /g;
  return $name;
}

sub _GetOLEDate {
  my ($self, $PPS) = @_;
  unless (defined ($self->{OLEDATE})) {
    # Make Date
    my $datearr;
    $datearr = $PPS->{Time2nd};
    $datearr = $PPS->{Time1st} unless($datearr);
    $self->{OLEDATE} = $self->_FormatDate($datearr) if $datearr;
  }
}

sub _FormatDate {
  my ($self, $datearr) = @_;

  # TODO: This is a little convoluted. Directly using strftime didn't seem
  # to work.
  my $datetime = mktime(@$datearr);
  return time2str("%a, %d %h %Y %X %z", $datetime);
}

# If we didn't get the date from the original header data, we may be able
# to get it from the SUBMISSION_ID:
# It seems to have the format of a semicolon-separated list of key=value
# pairs. The key l has a value with the format:
# <SERVER>-<DATETIME>Z-<NUMBER>, where DATETIME is the date and time in
# the format YYMMDDHHMMSS.
sub _SubmissionIdDate {
  my $self = shift;

  my $submission_id = $self->{SUBMISSION_ID} or return undef;
  $submission_id =~ m/l=.*-(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)Z-.*/
    or return undef;
  my $year = $1;
  $year += 100 if $year < 20;
  return $self->_FormatDate([$6,$5,$4,$3,$2-1,$year]);
}

sub _ParseItemName {
  my ($self, $name) = @_;

  if ($name =~ /^__substg1 0_(....)(....)$/) {
    my ($property, $encoding) = ($1, $2);
    if ($encoding eq ENCODING_UNICODE and not ($self->{HAS_UNICODE})) {
      warn "This MSG file contains Unicode fields." 
	. " This is currently unsupported.\n";
      $self->{HAS_UNICODE} = 1;
    } elsif (not (KNOWN_ENCODINGS()->{$encoding})) {
      warn "Unknown encoding $encoding. Results may be strange or wrong.\n";
    }
    return ($property, $encoding);
  } else {
    return (undef, undef);
  }
}

sub _SaveAttachment {
  my ($self, $mime, $att) = @_;

  my $ent = $mime->attach(
    Type => $att->{MIMETYPE},
    Encoding => $att->{ENCODING},
    Data => [],
    Filename => ($att->{LONGNAME} ? $att->{LONGNAME} : $att->{SHORTNAME}),
    Disposition => $att->{DISPOSITION}
  );

  my $handle;
  if ($handle = $ent->open("w")) {
    $handle->print($att->{DATA});
    $handle->close;
  } else {
    warn "Could not write data!";
  }
}

sub _SetAddressPart {
  my ($self, $adrname, $partname, $data) = @_;

  my $address = $self->{ADDRESSES}->{$adrname};
  $data =~ s/\000//g;
  #warn "Processing address data part $partname : $data\n";
  if (defined ($address->{$partname})) {
    if ($address->{$partname} eq $data) {
      warn "Skipping duplicate but identical address information for"
      . " $partname\n" if $self->{VERBOSE};
    } else {
      warn "Address information $partname inconsistent:\n";
      warn "    Original data: $address->{$partname}\n";
      warn "    New data: $data\n";
    }
  } else {
    $address->{$partname} = $data;
  }
}

# Set header fields
sub _AddHeaderField {
  my ($self, $mime, $fieldname, $value) = @_;

  my $oldvalue = $mime->head->get($fieldname);
  return if $oldvalue;
  $mime->head->add($fieldname, $value) if $value;
}

sub _Address {
  my ($self, $tag) = @_;
  my $name = $self->{$tag} || "";
  my $address = $self->{$tag . "_ADDR"} || "";
  return "$name <$address>";
}

# Find SMTP addresses for the given list of names
sub _ExpandAddressList {
  my ($self, $names) = @_;

  my $addresspool = $self->{ADDRESSES};
  my @namelist = split /; */, $names;
  my @result;
  name: foreach my $name (@namelist) {
    foreach my $address (@$addresspool) {
      if ($name eq $address->{NAME}) {
	my $addresstext = $address->{NAME} . " <";
	if (defined ($address->{SMTPADDRESS})) {
	  $addresstext .= $address->{SMTPADDRESS};
	} elsif ($address->{TYPE} eq "SMTP") {
	  $addresstext .= $address->{ADDRESS};
	}
	$addresstext .= ">";
	push @result, $addresstext;
	next name;
      }
    }
    push @result, $name;
  }
  return join ", ", @result;
}

sub _ParseHead {
  my ($self, $data) = @_;
  defined $data or return undef;
  # Parse full header date if we got that.
  my $parser = new MIME::Parser();
  $parser->output_to_core(1);
  $parser->decode_headers(1);
  $data =~ s/^Microsoft Mail.*$/X-MSGConvert: yes/m;
  my $entity = $parser->parse_data($data)
    or warn "Couldn't parse full headers!"; 
  my $head = $entity->head;
  $head->unfold;
  return $head;
}

# Find out if we need to construct a multipart message
sub _IsMultiPart {
  my $self = shift;

  return (
    ($self->{BODY_HTML} and $self->{BODY_PLAIN})
      or @{$self->{ATTACHMENTS}}>0
  );
}

# Copy original header data.
# Note: This should contain the Date: header.
sub _CopyHeaderData {
  my ($self, $mime) = @_;

  my $head = $self->_ParseHead($self->{HEAD}) or return;

  foreach my $tag (grep {!$skipheaders->{$_}} $head->tags) {
    foreach my $value ($head->get_all($tag)) {
      $mime->head->add($tag, $value);
    }
  }
}

# Set header fields
sub _SetHeaderFields {
  my ($self, $mime) = @_;

  # If we didn't get the date from the original header data, we may be able
  # to get it from the SUBMISSION_ID:
  $self->_AddHeaderField($mime, 'Date', $self->_SubmissionIdDate());

  # Third and last chance to set the Date: header; this uses the date the
  # MSG file was saved.
  $self->_AddHeaderField($mime, 'Date', $self->{OLEDATE});
  $self->_AddHeaderField($mime, 'Subject', $self->{SUBJECT});
  $self->_AddHeaderField($mime, 'From', $self->_Address("FROM"));
  #$self->_AddHeaderField($mime, 'Reply-To', $self->_Address("REPLYTO"));
  $self->_AddHeaderField($mime, 'To', $self->_ExpandAddressList($self->{TO}));
  $self->_AddHeaderField($mime, 'Cc', $self->_ExpandAddressList($self->{CC}));
  $self->_AddHeaderField($mime, 'Message-Id', $self->{MESSAGEID});
  $self->_AddHeaderField($mime, 'In-Reply-To', $self->{INREPLYTO});
}

package main;
use Getopt::Long;
use Pod::Usage;

# Setup command line processing.
my $verbose = '';
my $help = '';	    # Print help message and exit.
GetOptions('verbose' => \$verbose, 'help|?' => \$help) or pod2usage(2);
pod2usage(1) if $help;

# Get file name
my $file = $ARGV[0];
defined $file or pod2usage(2);
warn "Will parse file: $file\n" if $verbose; 

# Load and parse MSG file (is OLE)
my $Msg = OLE::Storage_Lite->new($file);
my $PPS = $Msg->getPpsTree(1);
$PPS or die "$file must be an OLE file";

# parse PPS tree
my $parser = new MSGParser();
$parser->set_verbosity(1) if $verbose;
$parser->parse($PPS);
$parser->print();

#
# Usage info follows.
#
__END__

=head1 NAME

msgconvert.pl - Convert Outlook .msg files to mbox format

=head1 SYNOPSIS

msgconvert.pl [options] <file.msg>

  Options:
    --verbose	be verbose
    --help	help message

=head1 OPTIONS

=over 8

=item B<--verbose>

    Print information about skipped parts of the .msg file.

=item B<--help>

    Print a brief help message.

=head1 DESCRIPTION

This program will output the message contained in file.msg in mbox format
on stdout. It will complain about unrecognized OLE parts on
stderr.

=head1 BUGS

Not all data that's in the .MSG file is converted. There simply are some
parts whose meaning escapes me. One of these must contain the date the
message was sent, for example. Formatting of text messages will also be
lost. YMMV.

=cut
