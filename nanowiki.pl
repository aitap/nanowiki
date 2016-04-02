#!/usr/bin/env perl
package App::NanoWiki::admincmd;
use Mojo::Base 'Mojolicious::Command';
has description => 'Administrative commands for NanoWiki';
has usage => <<EOM;
Usage: $0 admincmd <command> [arguments...]

Available commands:

init
	Write default config file, create the database file and tables
delete <page> [page ...]
	Delete specified pages completely
rename <from> <to>
	Move a page from one path to another. Ordinary paths look like
	"Welcome/subpage/subsubpage".
export <directory>
	Export the wiki as a series of text files containing Textile
	source of the articles to the specified directory.

Warning: the commands in question are potentially destructive and
should be used with caution!
EOM

sub run {
	my ($self, @args) = @_;
	use Mojo::Util qw(encode decode);
	my %commands = (
		init => sub {
			use Data::Dumper; # shock, horrors! writing config using Dumper!
			use autodie; # open, print, close
			my $config = $self->app->config;
			open my $conf_handle, ">:utf8", $self->app->conffile; # still looks ugly?
			print $conf_handle Data::Dumper::->new([$config], ['config'])->Terse(1)->Useqq(1)->Dump;
			close $conf_handle;
			my $dbh = $self->app->dbh;
			$dbh->query($_) for (
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
"create index if not exists sessions_id_expires on sessions (id, expires);", # look up whether a session is valid
"create index if not exists sessions_expires on sessions (expires);", # clean up stale sessions
			);
		},
		delete => sub {
			return unless @_; # delete from pages; -- haha
			say "Deleted "
				.$self->app->dbh->delete('pages', { title => { '=' , [ map { decode utf8 => $_ } @_ ] } })->rows
				." rows";
		},
		rename => sub {
			die "Usage: rename <from> <to>\n" unless @_ == 2;
			my ($from, $to) = map { decode utf8 => $_ } @_;
			(my $parent = $to) =~ s{/[^/]+$}{};
			say "Updated "
				.$self->app->dbh->update('pages', { title => $to, parent => $parent }, { title => $from })->rows
				." rows";
		},
		export => sub {
			use autodie; # chdir, open, close, print...
			use File::Path 'make_path';
			die "Usage: export <directory>\n" unless @_ == 1;
			my $dbh = $self->app->dbh; # it dies and takes the sth with it otherwise
			my $result = $dbh->query(
				"select p.title, p.src, p.time from pages p
				inner join (select title, max(time) as latest from pages group by title) gp
				on gp.title == p.title and p.time == gp.latest"
			);
			while (my $row = $result->array) {
				my ($title, $text, $time) = @$row;
				$title = encode utf8 => "$_[0]/$title.txt";
				(my $dirname = $title) =~ s{/[^/]+$}{};
				make_path $dirname;
				open my $write, ">:utf8:crlf", $title;
				print $write "$time # revision ".scalar(localtime $time)." -- please do not touch this line\n";
				print $write $text;
				print "$time $title\n";
			}
		},
		import => sub {
			use autodie; # open, readline...
			use File::Find 'find';
			die "Usage: import <directory>\n" unless @_ == 1 and -d $_[0];
			my ($dir) = @_;
			my $dbh = $self->app->dbh;
			find({wanted => sub {
				my $found = $File::Find::name;
				# we only care about *.txt files
				return unless -f $found and $found =~ /\.txt$/;
				open my $read, "<:utf8:crlf", $found;
				$found =~ s{^\Q$dir\E/}{}; $found =~ s/\.txt$//; $found = decode utf8 => $found;
				my $time = (scalar(<$read>) =~ /^\s*(\d+)/)[0];
				die "Can't read mtime of $File::Find::name; was the first line damaged?\n" unless $time;
				if (($dbh->query("select count(time) from pages where time > (?+0) and title = ?",$time, $found)->flat)[0]) {
					warn "$time $File::Find::name -- not importing because there are newer edits\n";
					return;
				}
				my $src = do { local $/; <$read> };
				if (($dbh->query("select count(time) from pages where time = (?+0) and src = ? and title = ?", $time, $src, $found)->flat)[0]) {
					print "$time $File::Find::name -- unchanged\n";
					return;
				}
				(my $parent = $found) =~ s{/[^/]+$}{}; # FIXME: this is copy-paste code
				$dbh->insert("pages", {
					title => $found, who => "local import", src => $src,
					html => App::NanoWiki::process_source($found,$src), time => time(), parent => $parent
				});
				print "$time $File::Find::name\n";
			}, no_chdir => 1}, $dir);
		},
		dump => sub {
			...;
		},
	);
	unless (@args and exists $commands{$args[0]}) {
		$self->help; exit(1);
	}
	$commands{$args[0]}->(@args[1..$#args]);
}

package App::NanoWiki;
use Mojolicious::Lite;
use DBIx::Simple;
use Session::Token;
use Text::Textile 'textile';
use Scalar::Util 'looks_like_number';

app->attr(conffile => $ENV{NANOWIKI_CONFIG} // "nanowiki.cnf"); # to use it from ::command

my $config = plugin Config => {
	file => app->conffile, default => {
		sqlite_filename => "nanowiki.db",
		session_entropy => 128,
		secrets => [Session::Token::->new(entropy => 2048)->get],
		root_page => "Welcome",
		session_timeout => 60*60*24*7, # sessions expire if not used in one week
		session_cleanup_probability => .05,
	}
};

app->secrets(app->config("secrets"));
app->sessions->default_expiration($config->{session_timeout});

helper 'dbh' => sub {
	return DBIx::Simple::->connect("dbi:SQLite:dbname=".$config->{sqlite_filename},"","",{sqlite_unicode => 1});
};

# from Mojolicious::Guides::Tutorial
helper 'whois' => sub {
	my $c     = shift;
	my $agent = $c->req->headers->user_agent || 'empty User-Agent';
	my $ip    = $c->tx->remote_address;
	return "$agent ($ip)";
};

helper 'normalize_path' => sub { # run once per request
	my $c = shift;
	my $path = $c->stash("path");
	# multiple /s mean nothing
	$path =~ s{/{2,}}{/}g;
	# process ../ in path
	$path =~ s{[^/]*/\.\./}{}g;
	# / in the end should also be sanitized
	$path =~ s{/$}{};
	$c->stash("path" => $path);
	return $path;
};

helper 'path_links' => sub { # transform /A/B/C into series of links to /A, /A/B, /A/B/C
	my $c = shift;
	my $path = $c->stash("path");
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
	my $dbh = $c->dbh;
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
	$to_check =~ tr/,/./;
	return (looks_like_number($to_check) and abs($to_check - $answer) <= 1e-2);
}

helper check_human => sub { # to be used in edit.htm and post controller
	my $c = shift;
	my $id = $c->session('id');
	my $dbh = $c->dbh();
	# i'm too reluctant to try to implement a cron-like something
	$dbh->query('delete from sessions where expires < (0+?)',time) if rand() < $config->{session_cleanup_probability};
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
			$dbh->update('sessions', { expires => time + $config->{session_timeout}, human => 1 }, { id => $id });
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
	my $dbh = $c->dbh;
	my $id = Session::Token::->new(entropy => $config->{session_entropy})->get;
	my ($challenge, $answer) = get_captcha();
	$dbh->insert(
		'sessions',
		{
			id => $id, expires => time + $config->{session_timeout},
			challenge => $challenge, answer => $answer,
		}
	);
	$c->session(id => $id);
	return Mojo::ByteStream::->new(qq{$challenge = <input name="captcha" type="text" required>});
};

# hopefully all pages will be children of the root node
get '/' => sub {
  my $c = shift;
  return $c->redirect_to('page', path => $config->{root_page});
};

get '/*path' => sub {
	my $c = shift;
	my $path = $c->normalize_path;
	my $edit = $c->param('edit');
	my $rev = $c->param('rev');
	my $dbh = $c->dbh;
	if (defined($edit)) { # show edit form
		$dbh
			->query(
				$edit ? 'select html, src from pages where title = ? and time = (0+?) order by time desc limit 1'
				      : 'select html, src from pages where title = ? order by time desc limit 1',
				$path,
				$edit || ()
			)->into(my($html, $src));
		return $c->render('edit', html => $html, src => $src);
	} elsif (defined($rev)) {
		# list revisions or select a specific one
		if ($rev and looks_like_number($rev)) { # 0 and '' are not valid revisions
			$dbh
				->query('select who, html from pages where title = ? and time = (0+?)', $path, $rev)
				->into(my($who, $html))
				or return $c->render('edit', msg => 'Invalid revision number', src => '', html => '', status => 404);
			return $c->render('page', html => $html, who => $who, time => $rev);
		} else { # asked for list of revisions
			my @history = $dbh
				->select('pages', [qw/time who/], { title => $path }, { -desc => 'time' })
				->arrays;
			return $c->render('edit', msg => 'Page not found', src => '', html => '', status => 404)
				unless @history;
			return $c->render('history', history => \@history);
		}
	} else { # just plain view last revision
		$dbh
			->query('select who, html, time from pages where title = ? order by time desc limit 1', $path)
			->into(my($who, $html, $time))
			or return $c->render('edit', msg => 'Page not found, create one now?', src => '', html => '', status => 404);
		return $c->render('page', html => $html, who => $who, time => $time);
	}
} => 'page';

sub process_source {
	use Mojo::Util qw(xml_escape);
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
		'<a href="'.Mojo::URL::->new(
			  ($href =~ m[^/]) ? $href # absolute link
			: ($href =~ m[^\.\.\/]) ? "/" # sibling link
				. (($path =~ m[(.*/)[^/]+$])[0] || '') # empty on root page
				. ($href =~ m[^\.\.\/(.*)])[0]
			: "/$path/$href" # child link
		)
		.'">'.xml_escape(
			$text || ($href =~ m[([^/]+)$])[0]
		).'</a>';
	}gxe;
	return textile($src);
}

post '/*path' => sub {
	my $c = shift;
	my $path = $c->normalize_path;
	my $src = $c->param("src");
	return $c->render('edit', msg => 'Invalid request (CSRF)', src => $src, html => '', status => 403)
		if $c->validation->csrf_protect->has_error;
	return $c->render('edit', msg => 'Invadid CAPTCHA', src => $src, html => '', status => 403)
		unless $c->check_human;
	(my $parent = $path) =~ s{/[^/]+$}{};
	my $preview = $c->param("preview");
	my $exit = $c->param("exit");
	my $html = process_source($path,$src);
	my $time = time;
	my $who = $c->whois;
	if ($preview) { # no save, no redirect
		return $c->render('edit', html => $html, src => $src, msg => "Preview mode");
	}
	# else save the data and decide where to redirect
	$c->dbh->insert('pages', { title => $path, who => $who, src => $src, html => $html, time => $time, parent => $parent })
		or return $c->render('edit', html => $html, src => $src, who => $who, time => $time, msg => "Database returned error, please retry", status => 500);
	return $c->redirect_to($c->url_for("/$path")->query($exit ? 'rev' : 'edit', $time));
} => 'post';

push @{app->commands->namespaces}, __PACKAGE__;

app->start;
__DATA__

@@ page.html.ep
% layout 'default';
% use POSIX 'strftime';
<div class="children"><ul>
	<% for (children()) { %>
		<li><a href="/<%= url_for $_->[1] %>"><%= $_->[0] %></a></li>
	<% } %>
</ul></div>
<div class="content"><%== $html %></div>
<div class="footer">
	<a href="?edit=<%= $time %>">Edit</a>
	Revision <a href="?rev"><%= strftime "%Y-%m-%d %H:%M:%S" => localtime $time %></a> by <i><%= $who %></i>.
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
			<textarea id="src" name="src" rows=30><%= $src %></textarea>
		</div>
		<div class="preview">
			<%== $html %>
		</div>
	</div>
	<%= captcha_field; %><br>
	<input type="submit" name="preview" value="Preview (without saving)">
	<input type="submit" name="exit" value="Save & exit">
	<input type="submit" value="Save & continue editing"><br>
	Available syntax: <a href="http://www.w3.org/MarkUp/Guide/">HTML</a>, <a href="http://txstyle.org/">Textile</a>. Use the following style to link to other pages: <pre>[[Child Page Name]], [[/Full/Path/To/Page]], [[../Sibling Page Name]], [[Page Name|Link Text]]</pre>
</form>

@@ history.html.ep
% layout 'default';
% use POSIX 'strftime';
<table>
<tr>
	<th>Date&time</th>
	<th>Author</th>
</tr>
<% for my $row (@$history) { %>
	<tr>
		<td><a href="?rev=<%= $row->[0] %>"><%= strftime "%Y-%m-%d %H:%M:%S" => localtime $row->[0] %></a></td>
		<td><%= $row->[1] %></td>
	</tr>
<% } %>

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
				float: right;
				width: 18%;
				background-color: #eeeeee;
				margin: 10px;
				border-radius: 5px;
			}
			.content_block {
				text-align: justify;
				margin: 5px;
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
				height: 100%;
			}
			textarea {
				width: 95%;
				height: 100%;
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
		<div class="content_block">
			<div class="path_links">
				<% for (path_links()) { %>
					/ <a href="<%= url_for $_->[1] %>"><%= $_->[0] %></a>
				<% } %>
			</div>
			<%= content %>
		</div>
  </body>
</html>
