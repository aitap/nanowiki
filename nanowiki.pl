#!/usr/bin/env perl
package App::NanoWiki::admincmd;
use Mojo::Base 'Mojolicious::Command';
has description => 'Administrative commands for NanoWiki';
has usage => <<EOM;
Usage: $0 admincmd <defaults|createdb|prune_history>

Available commands:

init
	Write default config file, create the database file and tables
prune_history
	Delete all the revisions of all pages except the latest ones

Warning: the commands in question are potentially destructive and
should be used with caution!
EOM

sub run {
	use DBI;
	my ($self, @args) = @_;
	my %commands = (
		init => sub {
			# XXX: should I really `use` here?
			use Config::Tiny;
			use Session::Token;
			# FIXME: code duplication, move $conffile to helper?
			my $conffile = $ENV{NANOWIKI_CONFIG} // "nanowiki.ini";
			my $cnf = Config::Tiny::->read($conffile, "utf8") || Config::Tiny::->new;
			for ($cnf->{_}) {
				$_->{sqlite_filename} //= "nanowiki.db";
				$_->{session_entropy} //= 128;
				$_->{secret} //= Session::Token::->new(entropy => 2048)->get;
				$_->{root_page} //= "Welcome";
				$_->{session_timeout} //= 60*60*24*7; # sessions expire if not used in one week
				$_->{session_cleanup_probability} //= .05;
			}
			$cnf->write($conffile, "utf8");
			my $dbh = DBI::->connect(
				"dbi:SQLite:dbname=".$cnf->{_}{sqlite_filename},
				"","",
				{ RaiseError => 1, sqlite_unicode => 1 },
			);
			$dbh->do($_) for (
"create table if not exists pages (
	title text,
	who text,
	src text,
	html text,
	time integer,
	parent text
);",
"create index if not exists pages_title on pages (title);", # GET /path/to/page
"create index if not exists pages_title_time on pages (title, time);", # GET /path/to/page?rev=1234
"create index if not exists pages_parent on pages (parent);", # list of children
"create table if not exists sessions (
	id text primary key, -- from Session::Token
	human bool,
	expires integer,
	challenge text, -- some CAPTCHAs may want to know [part of] the question before checking answer
	answer text
);",
"create index if not exists sessions_id on sessions (id);", # update valid sessions and delete invalid ones
"create index if not exists sessions_id_expires on sessions (id, expires);", # look up whether a session is valid
"create index if not exists sessions_expires on sessions (expires);", # clean up stale sessions
			);
		},
		prune_history => sub {
			...;
		}
	);
	unless (@args == 1 and exists $commands{$args[0]}) {
		$self->help; exit(1);
	}
	$commands{$args[0]}->();
}

package App::NanoWiki;
use Mojolicious::Lite;
use DBIx::Simple;
use Session::Token;
use Config::Tiny;
use Text::Textile 'textile';

my $conffile = $ENV{NANOWIKI_CONFIG} // "nanowiki.ini";
my $config = Config::Tiny::->read($conffile, "utf8") || Config::Tiny::->new;

app->secrets([$config->{_}{secret}]);

sub dbh {
	return DBIx::Simple::->connect("dbi:SQLite:dbname=".$config->{_}{sqlite_filename},"","",{sqlite_unicode => 1});
}

# from Mojolicious::Guides::Tutorial
helper 'whois' => sub {
	my $c     = shift;
	my $agent = $c->req->headers->user_agent || 'empty User-Agent';
	my $ip    = $c->tx->remote_address;
	return "$agent ($ip)";
};

helper 'path_links' => sub { # transform /A/B/C into series of links to /A, /A/B, /A/B/C
	my $c = shift;
	my $path = $c->stash("path");
	# multiple /s mean nothing
	$path =~ s{/{2,}}{/}g;
	# process ../ in path
	$path =~ s{[^/]*/\.\./}{}g;
	# / in the end should also be sanitized
	$path =~ s{/$}{};
	# split path into parts to linkify them in the template
	my @pathspec = map { [ $_ ] } split /\//, $path;
	$pathspec[0][1] = "/$pathspec[0][0]";
	$pathspec[$_][1] = "$pathspec[$_-1][1]/$pathspec[$_][0]" for 1..$#pathspec;
	return @pathspec;
};

helper 'title_from_path' => sub { # /A/B/C -> C
	my $c = shift;
	my ($title) = $c->stash("path") =~ m{([^/]+)$};
	return $title;
};

helper children => sub { # all pages which have current as their parent
	my $c = shift;
	my $dbh = dbh;
	return
		map {
			my ($title) = m{([^/]+)$};
			[ $title, $_ ]
		}
		$dbh->query("select distinct(title) from pages where parent = ?", $c->stash("path"))->flat
		;
};

sub get_captcha {
	my @operands = qw(- + / *);
	my $challenge = int rand 20;
	$challenge .= " ".$operands[int rand @operands]." ".(int(rand 20)+1) for 1..2;
	my $answer = eval $challenge; # string eval! shock, horrors!
	my %digits = map {
		my $dig = $_;
		( $dig => [ map { chr ($_ + $dig) } (0x1d7cE, 0x1d7d8, 0x1d7e2, 0x1d7ec, 0x1d7f6, 0xff10, 0x30) ] )
	} (0..9);
	$challenge =~ s/(\d)/$digits{$1}[int rand @{$digits{$1}}]/ge;
	return ($challenge, $answer);
}

sub check_captcha {
	my ($challenge, $answer, $to_check) = @_;
	use Scalar::Util 'looks_like_number';
	$to_check =~ tr/,/./;
	return (looks_like_number($to_check) and abs($to_check - $answer) <= 1e-2);
}

helper check_human => sub { # to be used in edit.htm and post controller
	my $c = shift;
	my $id = $c->session('id');
	my $dbh = dbh();
	# i'm too reluctant to try to implement a cron-like something
	$dbh->query('delete from sessions where expires < (0+?)',time) if rand() < $config->{_}{session_cleanup_probability};
	if ( $id
		&& $dbh
			->query('select human, expires, challenge, answer from sessions where id = ? and expires > (0+?)',$id,time)
			->into(my($human, $expires, $challenge, $answer))
	) { # session has a somewhat valid id
		if (!$human) { # there is a valid captcha session, but not a human session => must be an answer
			my $to_check = $c->param('captcha');
			if (defined $to_check and check_captcha($challenge, $answer, $to_check)) { # valid answer
				$human = 1;
			} else { # no answer or invalid
				$dbh->delete('sessions',{id=>$id}); # delete the session so it won't be used again
			}
		}
		if ($human) { # passed captcha sometime in the past => touch the session in DB and cookies
			$dbh->update('sessions', { expires => time + $config->{_}{session_timeout}, human => 1 }, { id => $id });
			$c->session(id => $id); # touch session->id to make it last longer; XXX: is it needed?
			return 1; # confirmed human; free to pass
		}
	} # else there is no valid session in the first place => possible unhuman
	return;
};

helper captcha_field => sub {
	my $c = shift;
	return "" if $c->check_human;
	# at this point: either the session was valid and there is no captcha, or the session does not exist
	# even if there was a session ID, there isn't now => captcha_field can feel free to create a new one
	my $dbh = dbh;
	my $id = Session::Token::->new(entropy => $config->{_}{session_entropy})->get;
	my ($challenge, $answer) = get_captcha();
	$dbh->insert(
		'sessions',
		{
			id => $id, expires => time + $config->{_}{session_timeout},
			challenge => $challenge, answer => $answer,
		}
	);
	$c->session(id => $id);
	return Mojo::ByteStream::->new(qq{$challenge = <input name="captcha" type="text" required>});
};

# hopefully all pages will be children of the root node
get '/' => sub {
  my $c = shift;
  return $c->redirect_to('page', path => $config->{_}{root_page});
};

get '/*path' => sub {
	my $c = shift;
	my $path = $c->stash('path');
	my $edit = defined($c->param('edit'));
	my $rev = $c->param('rev');
	my $dbh = dbh;
	if ($edit) { # show edit form
		$dbh
			->query('select html, src from pages where title = ? order by time desc limit 1', $path)
			->into(my($html, $src));
		return $c->render('edit', html => $html, src => $src);
	} elsif (defined($rev)) {
		# list revisions or select a specific one
		...; # TODO
	} else { # just plain view last revision
		$dbh
			->query('select who, html, time from pages where title = ? order by time desc limit 1', $path)
			->into(my($who, $html, $time))
			or return $c->render('edit', msg => 'Page not found, create one now?', src => '', html => '');
		return $c->render('page', html => $html, who => $who, time => $time);
	}
} => 'page';

sub process_wiki_links {
	use Mojo::Util qw(url_escape xml_escape);
	my ($path, $src) = @_;
	$src =~ s{ # giant regular expressions! shock, horrors!
		\[\[   # wikilink begins with [[
		([^|\]]+) # required part (page name) with no ] or | inside allowed
		(?:    # optional part: |link_text
		 \|
		 ([^\]]+)
		)?
		\]\]
	}{
		my ($href, $text) = ($1, $2);
		'<a href="'.url_escape(
			  ($href =~ m[^/]) ? $href # absolute link
			: ($href =~ m[^\.\.\/]) ? "/" # sibling link
				. ($path =~ m[(.*/)[^/]+$])[0]
				. ($href =~ m[^\.\.\/(.*)])[0]
			: "/$path/$href" # child link
		, q{<>&'"}) # URLencode only XML-unsafe characters
		.'">'.xml_escape(
			$text || ($href =~ m[([^/]+)$])[0]
		).'</a>';
	}gxe;
	return $src;
}

post '/*path' => sub {
	my $c = shift;
	my $path = $c->stash("path");
	my $src = $c->param("src");
	return $c->render('edit', msg => 'Invalid request (CSRF)', src => $src, html => '')
		if $c->validation->csrf_protect->has_error;
	return $c->render('edit', msg => 'Invadid CAPTCHA', src => $src, html => '')
		unless $c->check_human;
	(my $parent = $path) =~ s{/[^/]+$}{};
	my $preview = $c->param("preview");
	my $exit = $c->param("exit");
	my $html = textile(process_wiki_links($path,$src));
	my $dbh = dbh;
	dbh->insert('pages', { title => $path, who => $c->whois, src => $src, html => $html, time => time, parent => $parent })
		unless $preview;
	return $c->render($exit ? 'page' : 'edit', html => $html, src => $src);
} => 'post';

push @{app->commands->namespaces}, __PACKAGE__;

app->start;
__DATA__

@@ page.html.ep
% layout 'default';
<% if (my $revisions = $self->stash("history")) { %>
	<p class="history"><!-- TODO --></p>
<% } %>
<div class="content"><%== $html %></div>
<div class="footer">
	<a href="?edit">Edit</a> <!--<a href="?rev">History</a>-->
	<% if (my $who = $self->stash("who") and my $time = $self->stash("time")) { %>
		Revision <%= $time %> by <i><%= $who %></i>.
	<% } %>
</div>

@@ edit.html.ep
% layout 'default';
<% if (my $msg = $self->stash("msg")) { %>
	<div class="message"><%= $msg %></div>
<% } %>
<form method="post">
	%= csrf_field;
	<div class="edit_container">
		<div class="textarea">
			<textarea id="src" name="src" rows=10><%= $src %></textarea>
		</div>
		<div class="preview">
			<%== $html %>
		</div>
	</div>
	<%= captcha_field; %><br>
	<input type="submit" name="preview" value="Preview (without saving)">
	<input type="submit" name="exit" value="Save & exit">
	<input type="submit" value="Save & continue editing"><br>
	Available syntax: <a href="http://www.w3.org/MarkUp/Guide/">HTML</a>, <a href="http://txstyle.org/">Textile</a>. Use the following style to link to other pages: <pre>[[Child Page Name]], [[/Full/Path/To/Page]], [[../Sibling Page Name]], [[Page Name|Link Text]]</pre>.
</form>

@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
	<head>
		<title><%= title_from_path() %></title>
		<style type="text/css">
			.header {
				text-align: center;
			}
			.children {
				float: left;
				width: 18%;
				background-color: #eeeeee;
				margin: 10px;
				border-radius: 5px;
			}
			.content_block {
				margin-left: 20%;
			}
			.path_links, .footer {
				border: 1px solid black;
			}
			.edit_container {
				display: block;
				overflow: auto;
				width: 100%;
			}
			.textarea, .preview {
				width: 49%;
				float: left;
			}
			textarea {
				width: 90%;
				height: auto;
			}
			.message {
				background: #ffeeee;
				border-radius: 10px;
				border: 1px solid #110000;
				text-align: center;
			}
		</style>
	</head>
	<body>
		<div class="header"><h1><%= title_from_path() %></h1></div>
		<div class="children"><ul>
			<% for (children()) { %>
				<li><%= link_to $_->[0], "/$_->[1]" %></li>
			<% } %>
		</ul></div>
		<div class="content_block">
			<div class="path_links">
				<% for (path_links()) { %>
					/ <%= link_to $_->[0], $_->[1] %>
				<% } %>
			</div>
			<%= content %>
		</div>
  </body>
</html>
