#!/usr/bin/env perl

# Copyright (c) 2015 Pierre-Yves Ritschard

# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:

# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

use CPAN::Meta::YAML;
use HTTP::Tiny;
use File::Basename;
use File::Path qw(make_path mkpath);
use File::Temp qw(tempfile);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError) ;

use warnings;
use strict;

use constant {
  METADATA_HOST => "169.254.169.254",
  IMG_USER_NAME => 'cloud-user',
};

sub get_data {
  my ($host, $path) = @_;
  my $response = HTTP::Tiny->new->get("http://$host/latest/$path");
  return unless $response->{success};
  return $response->{content};
};

sub get_metadata {
  my ($type) = @_;
  my $response = HTTP::Tiny->new->get(sprintf('http://%s/latest/%s', METADATA_HOST, $type));
  return unless $response->{success};
  return $response->{content};
}

sub sys_cmd {
  system(@_) == 0
    or die "\"system @_\" failed: $?";
}

sub lookup_uid_gid {
  my $username = shift;

  setpwent;
  my $uid = getpwnam $username;
  return unless( $uid );
  endpwent;

  setgrent;
  my $gid = getgrnam $username;
  endgrent;

  return ($uid, $gid);
}

sub install_pubkeys {
  my $username = shift;
  my ($user_uid,$user_gid) = lookup_uid_gid $username;

  print STDOUT "Deploy SSH key for user $username\n";

  return unless (defined $user_uid && defined $user_gid);
  return unless (-d "/home/$username");
  my $ssh_dir = "/home/$username/.ssh";

  make_path($ssh_dir, { verbose => 0, mode => 0700 });

  open my $fh, ">>", "$ssh_dir/authorized_keys";
  printf $fh "#-- key added by cloud-init at your request --#\n";
  printf $fh "%s\n", $_ for (@_);
  close $fh;

  chown $user_uid, $user_gid, $ssh_dir, "$ssh_dir/authorized_keys";
}

sub action_set_hostname {
  my $hostname = shift;

  return unless ($hostname);

  open my $fh, ">", "/etc/myname";
  printf $fh "%s\n", $hostname;
  close $fh;
  sys_cmd("hostname " . $hostname);
}

sub action_create_user {
  my $user_info = shift;

  return unless ($user_info->{'name'});

  my @adduser_args;

  my $group_list = ref $user_info->{'groups'} eq 'ARRAY' ? join ',', @{$user_info->{'groups'}} : q('');
  push @adduser_args, '-batch ' . join (' ', $user_info->{'name'}, $group_list, map { $_ || '' } @{$user_info}{'gecos', 'passwd'});
  push @adduser_args, '-group ' . ($user_info->{'primary-group'} // 'USER');
  push @adduser_args, '-shell ' . ($user_info->{'shell'} // 'nologin');
  push @adduser_args, '-class ' . ($user_info->{'class'} // 'default');

  sys_cmd('adduser ' . join ' ', @adduser_args);

  if (ref $user_info->{'ssh-authorized-keys'} eq 'ARRAY') {
    install_pubkeys $user_info->{'name'}, @{$user_info->{'ssh-authorized-keys'}};
  }
}

sub apply_user_data {
  my $data = shift;

  action_set_hostname($data->{fqdn})
    if (defined($data->{fqdn}));

  if (defined($data->{manage_etc_hosts}) &&
      defined($data->{fqdn}) &&
      $data->{manage_etc_hosts} eq 'true') {
    open my $fh, ">>", "/etc/hosts";
    my ($shortname) = split(/\./, $data->{fqdn});
    printf $fh "127.0.1.1 %s %s\n", $shortname, $data->{fqdn};
    close $fh;
  }

  if (ref $data->{users} eq 'ARRAY') {
    action_create_user $_ foreach (@{$data->{users}});
  }

  if ($data->{'pkg-path'} && $data->{'pkg-add'}) {
    sys_cmd("PKG_PATH=$data->{'pkg-path'} pkg_add -aI " . join ' ', @{$data->{'pkg-add'}});
  }

  if (defined($data->{packages})) {
    foreach my $package (@{ $data->{packages} }) {
      system("pkg_add " . $package);
    }
  }

  if (defined($data->{write_files})) {
    foreach my $item (@{ $data->{write_files} }) {
      mkpath [dirname($item->{path})], 0, 0755;
      open my $fh, ">", $item->{path};
      print $fh $item->{content};
      if (defined($item->{permissions})) {
        my $perms = oct($item->{permissions});
        chmod($perms, $fh);
      }
      if (defined($item->{owner})) {
        my ($user_name, $group_name) = split(/\:/, $item->{owner});
        my $uid = getpwnam $user_name;
        my $gid = getgrnam $group_name;
        chown $uid, $gid, $fh;
      }
      close $fh;
    }
  }

  if (defined($data->{runcmd})) {
    foreach my $runcmd (@{ $data->{runcmd} }) {
      system("sh -c \"$runcmd\"");
    }
  }
}

sub cloud_init {
    my $host = METADATA_HOST;

    my $compressed = get_metadata('user-data');
    my $data;
    gunzip \$compressed => \$data;

    my $hostname = get_metadata('meta-data/hostname');
    action_set_hostname($hostname)
      if (defined($hostname));

    if (defined($data)) {
        if ($data =~ /^#cloud-config/) {
            $data = CPAN::Meta::YAML->read_string($data)->[0];
            apply_user_data $data;
        } elsif ($data =~ /^#\!/) {
            my ($fh, $filename) = tempfile("/tmp/cloud-config-XXXXXX");
            print $fh $data;
            chmod(0700, $fh);
            close $fh;
            sys_cmd("sh -c \"$filename && rm $filename\"");
        }
    }

    my $pubkeys = get_metadata('meta-data/public-keys');
    chomp($pubkeys);
    install_pubkeys IMG_USER_NAME, map {
      $_ =~ /^(\d+)=/;
      get_metadata(sprintf('meta-data/public-keys/%d/openssh-key', $1));
    } split /\n/, $pubkeys;
}

sub action_deploy {
    #-- rc.firsttime stub
    open my $fh, ">>", "/etc/rc.firsttime";
    print $fh <<'EOF';
# run cloud-init
path=/usr/local/libdata/cloud-init.pl
echo -n "cloud-init first boot: "
perl $path cloud-init && echo "done."
EOF
    close $fh;

    #-- remove generated keys and seeds
    unlink glob "/etc/ssh/ssh_host*";
    unlink "/etc/random.seed";
    unlink "/var/db/host.random";
    unlink "/etc/isakmpd/private/local.key";
    unlink "/etc/isakmpd/local.pub";
    unlink "/etc/iked/private/local.key";
    unlink "/etc/isakmpd/local.pub";

    #-- remove cruft
    unlink "/tmp/*";
    unlink "/var/db/dhclient.leases.vio0";

    #-- disable root password
    sys_cmd("chpass -a 'root:*:0:0:daemon:0:0:Charlie &:/root:/bin/ksh'")
}

#-- main
my ($action) = @ARGV;

action_deploy if ($action eq 'deploy');
cloud_init if ($action eq 'cloud-init');
