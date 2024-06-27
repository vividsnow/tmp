#!/usr/bin/env perl
# terminal app for soundcloud personal stream (play, pause, forward, like, unlike, open in browser..). uses mpv
use utf8; use strict; use warnings;
use Getopt::Std 'getopt';
use HTTP::Tiny; use JSON::PP;
use IO::Uncompress::Gunzip 'gunzip';
use Socket qw'AF_UNIX SOCK_STREAM PF_UNSPEC';
use List::Util qw'min max';
use Encode::Locale;
use POSIX qw'setsid sigaction SIGHUP SA_SIGINFO';
use POSIX::SigAction;
use IO::Socket::Socks::Wrapper ();

die 'needs ssl support' unless HTTP::Tiny->can_ssl;

$0 = 'soundcloud-term';
binmode $_, ':encoding(console_out)' for *STDOUT, *STDERR;

use constant debug => $ENV{debug};
getopt(stp => \ my %o);
die 'specify token' unless my $token = $o{t}; # look it up in 'oauth_token' cookie

IO::Socket::Socks::Wrapper->import(
    'HTTP::Tiny::Handle::connect()' => {qw'ProxyAddr localhost SocksVersion 5 Timeout 5 ProxyPort', $o{p}}
) if $o{p};

my $api = 'https://api-v2.soundcloud.com/';
my $ua = HTTP::Tiny->new(
    default_headers => +{qw'accept-encoding gzip authorization', 'OAuth '.$token},
    timeout => 10, agent => '');

$^F += 1; # this should be before any other sock ops, (mpv will listen unnamed sock)
die $! unless socketpair my $sc, my $sp, AF_UNIX, SOCK_STREAM, PF_UNSPEC;

$\ = "\n";

print $ua->get('https://ipinfo.io')->{content} if debug;

my %me = map { %$_{qw'id username'} } get('me');

die 'no stream list' unless my @stream =
    map {
        my $asset = $_->{my $type = $_->{type} =~ '^playlist' ? 'playlist' : 'track'};
        +{
            type => $type,
            %$asset{qw'id permalink_url title'},
            (map {; aid => $_->{id}, aname => $_->{username} } $asset->{user}),
            (map {; pid => $_->{id}, pname => $_->{username} } $_->{user}),
        } }
    do {
        my ($limit, $offset, @r) = ($o{s}, 0);
        while () {
            my $r = get('stream'.($limit ? '?limit='.$limit : '').($offset ? '&offset='.$offset : ''));
            last unless my @t = @{$r->{collection}};
            push @r, @t;
            last if !$limit || @r >= $limit;
            last unless $r->{next_href};
            last unless $offset = ($r->{next_href}=~/offset=(\d+)/a)[0] }
        @r };

my (@cmd, %cur) = (qw'list10 play');

$SIG{INT} = $SIG{TERM} = sub { print "got int/term"; @cmd = 'exit' };
$SIG{CHLD} = sub {
    print "got chld" if debug;
    1 while wait > 0;
    push @cmd, 'next '.$cur{idx} if %cur;
    undef %cur };

$SIG{USR1} = sub { print 'sig: toggle'; push @cmd, 'toggle' };
$SIG{USR2} = sub { print 'sig: next'; push @cmd, 'next' };
sigaction(SIGHUP, POSIX::SigAction->new(
    sub {
        return unless my $cmd_no = $_[1]{status};
        return unless my $cmd = (qw'like infox jump+30')[$cmd_no - 1];
        print 'sig: ', $cmd;
        push @cmd, $cmd },
    undef, SA_SIGINFO)) or die $!;

my $last_cmd;
while () {
    {   ;
        $_ = shift @cmd and last if @cmd;
        local $SIG{ALRM} = sub { die };
        undef $_;
        eval { alarm 1; $_ = readline; alarm 0 };
        redo unless defined && length;
        chomp;
        $_ = $last_cmd unless length;
        $last_cmd = $_ }
    if (/^p(?:lay)?(?:\s*(\d+))?$/a) {
        my $idx = $1 // 0;
        push @cmd, 'stop', 'play '.$idx and next if %cur;
        if (my $pid = fork) {  @cur{qw'pid idx fh'} = ($pid, $idx, $sp) } # parent
        elsif (defined $pid) { # child
            close $sp;
            printf qq(playin %d %s "%s"\n), $idx, @{$stream[$idx]}{qw'type title'};
            $SIG{INT} = uc'ignore';
            die $! unless defined(my $fd = fileno $sc);
            exec mpv =>
		(debug ? '--msg-level=all=debug' : ('--terminal=no')),
		$o{p} ? '--ytdl-raw-options-append=proxy=socks5://127.0.0.1:'.$o{p} : (),
		qw'--audio-display=no', '--input-ipc-client=fd://'.$fd, $stream[$idx]{permalink_url};
            die 'exec fail:'.$! }
        else { die 'fork fail' } }
    elsif (/^l(?:ike)?(?:\s*(\d+))?$/) {
        my $i = $stream[$1 // $cur{idx}];
        printf "like: %s\n", lc put(sprintf 'users/%d/%s_likes/%d', $me{id}, @$i{qw'type id'}) }
    elsif (/^u(?:nlike)?(?:\s*(\d+))?$/) {
        my $i = $stream[$1 // $cur{idx}];
        printf "unlike: %s\n", lc del(sprintf 'users/%d/%s_likes/%d', $me{id}, @$i{qw'type id'}) }
    elsif (/^s(?:top)?$/) {
        next unless %cur;
        local $SIG{CHLD} = uc'default';
        local $SIG{PIPE} = sub { print "broken pipe: $!" };
        (warn 'write fail'), (kill uc'term', $cur{pid}) unless syswrite $cur{fh}, "quit\n";
        1 while wait > 0;
        undef %cur }
    elsif (/^t(?:oggle)?$/) {
        next unless %cur;
        local $SIG{PIPE} = sub { print "broken pipe: $!" };
        syswrite $cur{fh}, "cycle pause\n" }
    elsif (/^i(?:nfo)?(x)?(\d+)?$/) {
        next unless defined(my $idx = $2) or %cur;
        $idx //= $cur{idx};
        printf "track: %s\nurl: %s\n", @{$stream[$idx]}{qw'title permalink_url'};
        {   ; # url to clipbaord
            local $SIG{CHLD} = uc'default';
            open my $fh, '|-', qw'xclip -i -selection clipboard';
            printf $fh "%s\n", $stream[$idx]{permalink_url} }
        {   ; # open link in browser
            last unless $1;
            local $SIG{CHLD} = uc'default';
            last if fork;
            $SIG{INT} = uc'default';
            setsid or die $!;
            exit if fork;
            open STDOUT, '>', '/dev/null'; open STDERR, '>&', STDOUT; close STDIN;
            exec 'xdg-open', $stream[$idx]{permalink_url} or die $! }
        # report position and length for current playing
        next unless $cur{idx} == $idx;
        local $SIG{PIPE} = sub { print "broken pipe: $!" };
        for my $prop (qw'time-pos duration pid') {
            warn 'write fail' unless syswrite $cur{fh}, encode_json(+{
                command => ['get_property', $prop], request_id => my $req_id = int rand 1e3})."\n";
            local $/ = "\n";
            while (my $line = readline $cur{fh}) {
                chomp $line;
                warn 'fail to decode' unless my $reply = eval { decode_json $line };
                printf "%s: %s\n", $prop, $reply->{data} // $reply->{error} and last if
                    exists($reply->{request_id}) && $reply->{request_id} == $req_id } } }
    elsif (/^j(?:ump)?(?:\s*([+-])?(\d+))$/) { # jump to position absolutely/relatevely
        my ($how, $n) = ($1, $2);
        next unless %cur;
        local $SIG{PIPE} = sub { print "broken pipe: $!" };
        warn 'write fail' unless syswrite $cur{fh},
            sprintf "seek %s%s %s\n", $how//'', $n, $how ? 'relative' : 'absolute' }
    elsif (/^n(?:ext)?(?:\s*(\d+))?$/) {
        my $nxt = (($1 // (%cur ? $cur{idx} : -1)) + 1) % @stream;
        push @cmd, %cur ? 'stop' : (), 'play '.$nxt }
    elsif (/^li?st?\s*(\d+)?$/) {
        for my $idx (0..min($1 ? $1 - 1 : $#stream, $#stream)) {
            my $t = $stream[$idx];
            printf qq(%2d%s%s by %s via %s\n), $idx,
                $t->{type} =~ /^playlist/ ? '⯒' : ' ',
                @$t{qw'title aname pname'} } }
    elsif (/^(?:q(?:uit)?|ex(?:it)?)$/) {
        exit 0 unless %cur;
        push @cmd, qw'stop exit' }
    elsif (/^h(?:elp)?$/) {
        print <<~\txt;
        available commands:
        lN     listN    list N items, N is optional, all by default
        pN     playN    play N item, N is optional, first by default
        iN     info     show item info, copies current item url to clipboard
        ixN    infox    ... and opens browser (SIGHUP sigque 2)
        t      toggle   toggle playback (SIGUSR1)
        s      stop     stop playback
        lN     like     like current or N track (SIGHUP sigque 1)
        uN     unlike   unlike current or N track
        nN     nextN    forward 1 or N track (SIGUSR2)
        jN     jumpN    jump to N sec absolutely
        j+N    jump+N   jump to +N sec relatevely (SIGHUP sigque 3 = j+30)
        j-N    jump-N   jump to -N sec relatevely
        q      quit
        ex     exit

        *empty command repeats last command
        txt
    }
    else { printf "unknown command %s, try 'help'\n", $_ } }

sub get { unshift @_, 'get'; goto &req }
sub put { unshift @_, 'put'; goto &req }
sub del { unshift @_, 'delete'; goto &req }
sub req {
    my ($method, $what) = @_;
    my $r = $ua->$method($api.$what);
    printf ">> %s: %s\n", $method, $api.$what if debug;
    $r->{success}
        ? $r->{headers}{'content-length'}
          ? decode_json(
              ($r->{headers}{'content-encoding'}//'') eq 'gzip'
              ? do { gunzip(\$r->{content}, \ my $buf); $buf }
              : $r->{content})
          : 'code:'.$r->{status}
        : die sprintf "couldn't %s: %s\n", $method, $r->{reason} }
