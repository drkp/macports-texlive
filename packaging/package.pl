#!/usr/bin/env perl
use strict;
use warnings;
use autodie;
use File::Slurp;
use File::Basename;
use List::MoreUtils qw(uniq);

BEGIN {
    unshift (@INC, "/home/drkp/texlive-trunk/Master/tlpkg");
}

use TeXLive::TLPDB;
use TeXLive::TLPOBJ;
use File::Basename;


#
# Configuration
#

my $tlpdb = TeXLive::TLPDB->new(root => "/home/drkp/texlive-trunk/Master");
my $STAGE = "/home/drkp/texlive/packaging/stage/";
my $TEXMFSRC = "/home/drkp/texlive-trunk/Master";
my $PORTFILES = "/home/drkp/texlive/packaging/portfiles";
my $PORTFILEINCLUDE = "/home/drkp/texlive/packaging/portfileinclude";
my $EXISTINGPORTFILES = "/home/drkp/texlive/packaging/macports-tex/";

my $MAKE_PACKAGES=0;
my $MAKE_PORTFILES=1;
my $REVBUMP=1;


# Collections to skip packaging
#   texworks and wintools are Windows-specific
#   texinfo is installed by itself
#   documentation-greek appears to be empty
my @skip_collections = qw(collection-documentation-greek collection-texinfo collection-texworks collection-wintools);

# Individual packages to skip
my @skip_packages = qw(texlive-msg-translations texlive-scripts texlive.infra xindy asymptote latexmk detex t1utils psutils pstools ps2eps dvi2tty getafm pgf pdfjam latexdiff biber dvipng dot2texi lcdftypetools);

# Binaries we don't build
my @skip_binaries = qw(xdvi-xaw);

# Packages to move
my %relocate_packages; # = ("kastrup" => "texlive-generic-recommended");
my %relocate_packages_inv;
while ((my $pkg, my $coll) = each(%relocate_packages)) {
    push(@{$relocate_packages_inv{$coll}}, $pkg);
}

sub portname_from_collection {
    my $collection = shift;
    $collection =~ s/^collection-/texlive-/;
    $collection =~ s/-lang/-lang-/;
    $collection =~ s/extra$/-extra/;
    $collection =~ s/recommended$/-recommended/;
    return $collection
}

sub transitive_closure_of_colldepends {
    my $collection = shift;
    my (%cols, %pkgs);

    my $tlc = $tlpdb->get_package($collection);
    foreach my $tlpname ($tlc->depends) {
        if ($tlpname =~ m/^collection/) {
            $cols{$tlpname} = 1;
            my ($rcols, $rpkgs) = transitive_closure_of_colldepends($tlpname);
            foreach my $rcol (keys %$rcols) {
                $cols{$rcol} = 1;
            }
            foreach my $rpkg (keys %$rpkgs) {
                $pkgs{$rpkg} = 1;
            }
        } else {
            $pkgs{$tlpname} = 1;
        }
    }

    return (\%cols, \%pkgs);
}

sub add_checksums {
    my $checksums = shift;
    my $filename = shift;
    
    open(HASH, "openssl rmd160 $STAGE/$filename |");
    my $rmd160 = <HASH>;
    chomp($rmd160);
    $rmd160 =~ s/^.*= //g;
    close HASH;
    open(HASH, "openssl sha256 $STAGE/$filename |");
    my $sha256 = <HASH>;
    chomp($sha256);
    $sha256 =~ s/^.*= //g;
    close HASH;

    push(@$checksums, "$filename");
    push(@$checksums, "rmd160  $rmd160"); 
    push(@$checksums, "sha256  $sha256");
}


sub process_collection {
    my $collection = shift;
    my $portname = portname_from_collection($collection);
    print "Processing $portname ($collection)\n";
    my $tlc = $tlpdb->get_package($collection);
    my (@docfiles, @runfiles, @srcfiles, %binfiles, @pkgs, @colldepends);
    my (@formats, @maps, @languages);
    my ($rcols, $rpkgs) = transitive_closure_of_colldepends($collection);
    
    my $revision = $tlc->revision;
    my @queue = uniq($tlc->depends);
    if (exists $relocate_packages_inv{$portname}) {
        foreach my $relocatedpkg (@{$relocate_packages_inv{$portname}}) {
            print("  Adding relocated package $relocatedpkg\n");
            push(@queue, $relocatedpkg);
        }
    }
    foreach my $tlpname (@queue) {
        if ($tlpname ~~ @skip_packages) {
            print("  Skipping individual package $tlpname\n");
            next;
        }
        if (exists $relocate_packages{$tlpname} &&
            ($relocate_packages{$tlpname} ne $portname)) {
            print("  Skipping individual package $tlpname: moved to $relocate_packages{$tlpname}\n");
            next;
        }

        if ($tlpname =~ m/^collection/) {
            # Collection dependency. Add to our list.
            push(@colldepends, $tlpname);
        } else {
            my $tlp = $tlpdb->get_package($tlpname);
            if (!$tlp) {
                print "  $tlpname does not exist\n";
                next;
            }

            if ($tlp->revision > $revision) {
                $revision = $tlp->revision;
            }
            
            if (!($tlpname =~ m/\.x86_64-darwin$/)) {
                if (defined $tlp->shortdesc) {
                    push(@pkgs, ([$tlpname, $tlp->shortdesc]));
                } else {
                    push(@pkgs, ([$tlpname, ""]));
                }
            }
            push(@docfiles, $tlp->docfiles);
            push(@runfiles, $tlp->runfiles);
            push(@srcfiles, $tlp->srcfiles);
            for my $binfile (@{$tlp->binfiles->{'x86_64-darwin'}}) {
                #print " $tlpname provides $binfile\n";
                if (!(basename($binfile) ~~ @skip_binaries)) {
                    $binfiles{basename($binfile)} = 1;
                }
            }

            foreach ($tlp->depends) {
                if (/\.ARCH$/) {
                    s/\.ARCH$/.x86_64-darwin/;
                    push (@queue, $_);
                }
            }
                
            s/^RELOC/texmf-dist/ for(@docfiles);
            s/^RELOC/texmf-dist/ for(@runfiles);
            s/^RELOC/texmf-dist/ for(@srcfiles);
            # parse executes
            foreach my $execute ($tlp->executes) {
                my ($cmd, @args) = split(" ", $execute);
                if ($cmd eq 'AddFormat') {
                    my %r = TeXLive::TLUtils::parse_AddFormat_line(join(" ", @args));
                    push(@formats, \%r);
                } elsif ($cmd eq 'addMap') {
                    my $mapname = $args[0];
                    push(@maps, "Map $mapname");
                } elsif ($cmd eq 'addMixedMap') {
                    my $mapname = $args[0];
                    push(@maps, "MixedMap $mapname");
                } elsif ($cmd eq 'addKanjiMap') {
                    my $mapname = $args[0];
                    push(@maps, "KanjiMap $mapname");
                } elsif ($cmd eq 'AddHyphen') {
                    my %r = TeXLive::TLUtils::parse_AddHyphen_line(join(" ", @args));
                    if (defined($r{"error"})) {
                        die "AddHyphen error $r{'error'}";
                    }
                    my $synlist = "";
                    if (defined($r{"synonyms"})) {
                        $synlist = join(" ", @{$r{"synonyms"}});
                    }
                    my $line;
                    {
                        no warnings 'uninitialized';
                        $line = "$r{'name'} $r{'file'} $r{'lefthyphenmin'} $r{'righthyphenmin'} {$synlist} {$r{'file_patterns'}} {$r{'file_exceptions'}} {$r{'luaspecial'}} ";
                    }
                    push(@languages, $line);
                } else {
                    die "unknown command to execute: $cmd";
                }
            }
        }
    }

    # Check dependencies
    my %colldepsprovide;        # list of TL pkgs provided by colldeps
    foreach my $col (@colldepends) {
        my ($deprcols, $deprpkgs) = transitive_closure_of_colldepends($collection);
        foreach my $pkg (keys %$deprpkgs) {
            $colldepsprovide{$pkg} = 1;
        }
    }

    foreach my $pkg (@pkgs) {
        my $pkgname = $$pkg[0];
        my ($deprcols, $deprpkgs) = transitive_closure_of_colldepends($pkgname);
        foreach my $rpkg (keys %$deprpkgs) {
            if (!exists $colldepsprovide{$rpkg}) {
                if (!($rpkg =~ m/\.ARCH$/)) {
                    print "  $pkgname: $rpkg missing!\n";
                }
            }
        }
    }

    my $distname = "$portname-$revision";

    if ($MAKE_PACKAGES && ! -e "$STAGE/$distname-run.tar.xz") {
        my $pkgdir = "$STAGE/$distname";
        my $pkginfodir = "$pkgdir/tlpkginfo";
        mkdir $pkgdir;
        mkdir $pkginfodir;
        mkdir "$pkgdir/docfiles";
        mkdir "$pkgdir/runfiles";
        mkdir "$pkgdir/srcfiles";
        open(INFO, ">", "$pkginfodir/pkgs");
        foreach (@pkgs) {
            print INFO "$_->[0] $_->[1]\n";
        }
        open(INFO, ">", "$pkginfodir/docfiles");
        foreach (@docfiles) {
            system "mkdir -p $pkgdir/docfiles/".dirname($_);
            if (system("cp -a $TEXMFSRC/$_ $pkgdir/docfiles/$_") == 0) {
                print INFO "$_\n";
            }
        }    
        open(INFO, ">", "$pkginfodir/runfiles");
        foreach (@runfiles) {
            system "mkdir -p $pkgdir/runfiles/".dirname($_);
            if (system("cp -a $TEXMFSRC/$_ $pkgdir/runfiles/$_") == 0) {
                print INFO "$_\n";
            }
        }    
        open(INFO, ">", "$pkginfodir/srcfiles");
        foreach (@srcfiles) {
            system "mkdir -p $pkgdir/srcfiles/".dirname($_);
            if (system("cp -a $TEXMFSRC/$_ $pkgdir/srcfiles/$_") == 0) {
                print INFO "$_\n";
            }
        }
        close INFO;
        system "cd $STAGE && tar -cf $distname-run.tar $distname --exclude $distname/docfiles --exclude $distname/srcfiles && xz $distname-run.tar";
        system "cd $STAGE && tar -cf $distname-doc.tar $distname/docfiles && xz $distname-doc.tar";
        system "cd $STAGE && tar -cf $distname-src.tar $distname/srcfiles && xz $distname-src.tar";

    }

    if ($MAKE_PORTFILES) {
        # Compute hashes
        my @checksums;
        add_checksums(\@checksums, "$distname-run.tar.xz");
        add_checksums(\@checksums, "$distname-doc.tar.xz");
        add_checksums(\@checksums, "$distname-src.tar.xz");
        my $checksum_str = join(" \\\n                    ", @checksums);
        
        my $includetext = "";
        if (-e "$PORTFILEINCLUDE/$portname") {
            $includetext = read_file("$PORTFILEINCLUDE/$portname");
        } 

        # Figure out revision to use by checking the previous
        # portfile: if it has the same texlive revision, increment its
        # portfile revision; otherwise use zero
        my $oldportversion = 0;
        my $oldportrevision = 0;
        my $oldportfilename = "$EXISTINGPORTFILES/$portname/Portfile";
        if (-e $oldportfilename) {
            open(OLDPORTFILE, $oldportfilename);
            while (<OLDPORTFILE>) {
                if (/^version\s+(\d+)/) {
                    $oldportversion = $1;
                }
                if (/^revision\s+(\d+)/) {
                    $oldportrevision = $1;
                }
                
            }
            close(OLDPORTFILE);
        }
        my $portrevision;
            print "oldportversion = $oldportversion, revision = $revision";
        if ($oldportversion == $revision) {
            if ($REVBUMP) {
                $portrevision = $oldportrevision + 1;
            } else {
                $portrevision = $oldportrevision;
            }
        } else {
            $portrevision = 0;
        }
        
        # Make portfile
        my $longdesc;
        if ((defined($tlc->longdesc)) && (length($tlc->longdesc) > 0)) {
            $longdesc = $tlc->longdesc;
        } else {
            $longdesc = $tlc->shortdesc;
        }
        $longdesc =~ s/;/\\;/;
        mkdir "$PORTFILES/$portname";
        open(PORTFILE, ">", "$PORTFILES/$portname/Portfile");
        print PORTFILE <<"EOF";
# -*- coding: utf-8; mode: tcl; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- vim:fenc=utf-8:ft=tcl:et:sw=4:ts=4:sts=4
# \$Id\$

PortSystem          1.0
PortGroup           texlive 1.0

name                $portname
version             $revision
revision            $portrevision

categories          tex
maintainers         dports
license             Copyleft Permissive
description         TeX Live: $tlc->{shortdesc}
long_description    $longdesc

checksums           $checksum_str

EOF

        if (@colldepends) {
            my $depstring;
            foreach (@colldepends) {
                my $dep = portname_from_collection($_);
                $depstring .= " port:$dep"
            }
            $depstring =~ s/^.//;
            
        print PORTFILE <<"EOF"
depends_lib         $depstring

EOF
        }

        if (@formats) {
            print PORTFILE "texlive.formats     ";
            foreach my $r (@formats) {
                if (defined($r->{"error"})) {
                    die "AddFormat error $r->{'error'}";
                }
                if (!(exists $binfiles{$r->{'name'}})) {
                    print "  format $r->{'name'} binary not activated\n"
                }
                my $line = "$r->{'mode'} $r->{'name'} $r->{'engine'} $r->{'patterns'} {$r->{'options'}}";

                print PORTFILE " \\\n    {$line}";
            }
            print PORTFILE "\n\n";
        }
        if (@languages) {
            print PORTFILE "texlive.languages     ";
            foreach (@languages) {
                print PORTFILE " \\\n    {$_}";
            }
            print PORTFILE "\n\n";
        }
        if (@maps) {
            print PORTFILE "texlive.maps     ";
            foreach (@maps) {
                print PORTFILE " \\\n    {$_}";
            }
            print PORTFILE "\n\n";
        }

        if (%binfiles) {
            print PORTFILE "texlive.binaries    " . join(" ", sort(keys %binfiles)) . "\n\n";
        }
        

        print PORTFILE "$includetext\n";
        print PORTFILE "texlive.texmfport\n";
        
        close PORTFILE;
    }
}

if ($MAKE_PACKAGES) {
    if (! -e $STAGE) { mkdir $STAGE; }
}

if ($MAKE_PORTFILES) {
    mkdir $PORTFILES;
}


foreach my $pkg ($tlpdb->collections()) {
   if ($pkg ~~ @skip_collections) {
       print("Skipping $pkg\n");
       next;
   }
   process_collection($pkg);
}

#process_collection("collection-fontutils");
