NAME
====

pandoc-plain2perlpod.pl - a pandoc filter to munge plain output into Perl POD documentation.

SYNOPSIS
========

    pandoc -w plain -F pandoc-plain2perlpod.pl [OPTIONS]  FILE_NAME ...

DESCRIPTION
===========

pandoc-plain2perlpod.pl is a pandoc filter to munge plain output into Perl POD documentation, a poor man's custom writer implemented as a filter if you will.

It works by replacing or wrapping certain Pandoc AST elements with Span, Div and other elements with raw POD markup injected into their contents lists as inline Code elements which the plain writer renders as unadorned verbatim text.

HOW TEXT ELEMENTS ARE 'TRANSLATED'
==================================

Start and end of document
-------------------------

The raw POD blocks

``` pod
=pod

=encoding UTF-8
```

and

``` pod
=cut
```

are inserted at the beginning and end of the document.

Headers
-------

Headers are turned into POD `=head1`..`=head4` command paragraphs.

**Note** that while Pandoc, like HTML, recognises six levels of headers POD recognises only four, so level 5 and 6 headers are 'normalized' to `=head4` (moreover some ancient POD readers recognise only two header levels, so you may want to use definition lists below that!)

Bullet (unordered) lists
------------------------

Bullet lists are converted into `=over...=back` regions with an `=item *` for each list item.

Ordered lists
-------------

Ordered lists are converted into `=over...=back` regions with an `=item` reflecting the list marker style of the original Markdown list; however many POD converters only recognize digits followed by a period as ordered list markers, so you might want to stick to that!

Definition lists
----------------

Ordered lists are converted into `=over...=back` regions with an `=item` for each term and the contents of the definitions as paragraphs or other block elements below them. You may want to put blank lines between your terms and definitions to make sure that pandoc renders the definition contents as paragraphs, so that there are blank lines between them in the POD.

**Note** that both Pandoc definitions and POD `=item`s must fit on a single line!

Code blocks
-----------

Are left as Pandoc's plain writer normally renders them, indented with four spaces, which should get them rendered correctly by most POD parsers and formatters, unless they have a [`.raw_pod`](#raw_pod "pod:/"RAW POD"") class, in which case they will end up as unindented verbatim plain text.

Inline code
-----------

Inline code (`` `code()` ``) is wrapped in a POD `C<< ... >>` formatting code.
See [NESTED FORMATTING CODES](#nested_formatting_codes "pod:/"NESTED FORMATTING CODES"") below for how `<` and `>` inside code and nested formatting codes are handled (i.e. hopefully correctly).

Ordinary emphasis
-----------------

Ordinary emphasis (`*emph*` or `_emph_`) is wrapped in a POD `I<< ... >>` formatting code. See [NESTED FORMATTING CODES](#nested_formatting_codes "pod:/"NESTED FORMATTING CODES"") below for how nested formatting codes are handled (i.e. hopefully correctly).

Strong emphasis
---------------

Strong emphasis (`*strong*` or `_strong_`) is wrapped in a POD `B<< ... >>` formatting code. See [NESTED FORMATTING CODES](#nested_formatting_codes "pod:/"NESTED FORMATTING CODES"") below for how nested formatting codes are handled (i.e. hopefully correctly).

Special characters
------------------

The characters `<` and `>` in ordinary text are replaced by the POD entities `E<lt>` and `E<gt>`. Other special characters are left as literal UTF-8, and an `=encoding UTF-8` is inserted at the beginning of the POD. If you run into problems with that you should inform the maintainers of your POD formatters that we now live in the 21st century!

Links
-----

The handling of links is a bit complicated. If a link has a title as in `[link text](URL "title"` and the *title* has one of the prefixes `perldoc:`, `cpan:`, `pod:`, or `man:` the URL will be replaced with whatever comes after that prefix in the title, hopefully resulting in correct podlinks to Perl documentation, a CPAN module, some header in the current document or a man page. The following examples should make clear how it all works:

    [the perlfunc docs](http://perldoc.perl.org/perlfunc.html "perldoc:perlfunc")

        L<< the perlfunc docs|perlfunc >>

    [the Try::Tiny module](https://metacpan.org/pod/Try::Tiny "cpan:Try::Tiny")

        L<< the Try::Tiny module|Try::Tiny >>

    [METHODS above](#METHODS "pod:/\"METHODS\"")

        L<< METHODS above|/"METHODS" >>

    [the which(1) manpage](http://man.he.net/man1/which "man:which(1)")

        L<< the which(1) manpage|which(1) >>

    [Pandoc](http://johnmacfarlane.net/pandoc "The Pandoc homepage")

        L<< Pandoc|http://johnmacfarlane.net/pandoc >>

(**Note** the escaped inner quotes in the internal link example; they are unfortunately necessary!)

This filter does not treat the different title prefixes differently, but I plan to write a companion filter which will allow you to write things like

    [](0 "perldoc:perlfunc")
    [](0 "cpan:Try::Tiny/\"CAVEATS\"")
    [](0 "pod:/\"METHODS\"")
    [](0 "man:which(1)")

and get empty link texts and/or false URL values replaced by something sensible when not producing POD output.

RAW POD
=======

If you want to insert some raw POD, e.g. a `=for` paragraph, you can use an inline code element or a code block with a class `raw_pod`:

```` markdown
```{.raw_pod}
=for Something:
foo
bar
baz
```

reference`Z<>`{.raw_pod}(s)
````

I'm afraid that if you want to hide such raw POD when producing other formats you will have to write your own filter. The reason this feature exists is that it is so this filter itself inserts raw POD.

NESTED FORMATTING CODES
=======================

The filter tries to do the right thing with nested formatting codes, i.e. as you go outwards each nesting level gets one angle bracket more in its delimiters, starting with double brackets at the innermost level because I find that more readable, except for `E<lt>` and `E<gt>` for literal `<` and `>` outside code: `` **Foo _bar `baz`_** `` will be rendered as `B<<<< I<<< bar C<< baz >> >>> >>>>`, should your Markdown contain something like that.

The way the number of angle brackets around inline code which contains angle brackets is determined is rather crude but a least it avoids getting too few brackets in the delimiters: It matches the code string against the regex `/(\<+|\>+)/` and adds the length of the longest match to the counter keeping track of the formatting code nesting level, which is localized before the filtering routine recurses to process inner elements before inserting the delimiters of an outer element, so that the number of angle brackets in the delimiters increases outwards.

This means that something like `` `$foo->bar->baz->quux` `` will be rendered as `C<< $foo->bar->baz->quux >>` and something like `` `20 << 40` `` will be correctly rendered as `C<<< 20 << 40 >>>`. However in some cases the outer delimiters may get too 'wide', but they should never get too narrow.

If you prefer to have `E<lt>` and `E<gt>` for literal `<` and `>` also in inline code you can set a metadata key `pod_escape_lt_gt` to a true value either in a YAML metadata block in your Markdown file or with pandoc's `-M` option on the command line. This is especially handy if your inline code exemplifies POD formatting codes, as any formatting code can be legally nested inside the `C<>` formatting code!

TODO
====

A hack to make inline code elements with a `.file` class render as `F<< ... >>` formatting codes.

AUTHOR
======

Benct Philip Jonsson \<bpjonsson@gmail.com\>

COPYRIGHT
=========

Copyright 2014- Benct Philip Jonsson

LICENSE
=======

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

SEE ALSO
========
