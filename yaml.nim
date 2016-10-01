#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2016 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## This is the parent module of NimYAML, a package that provides facilities to
## generate and interpret `YAML <http://yaml.org>`_ character streams. Importing
## this package will import everything from all subpackages.
##
## There are three high-level APIs which are probably most useful:
##
## * The serialization API in `serialization <yaml.serialization.html>`_ enables
##   you to load YAML data directly into native Nim types, and reversely dump
##   native Nim types as YAML.
## * The DOM API in `dom <yaml.dom.html>`_ parses YAML files in a tree structure
##   which you can navigate.
## * The JSON API in `tojson <yaml.tojson.html>`_ parses YAML files into the
##   Nim stdlib's JSON structure, which may be useful if you have other modules
##   which expect JSON input. Note that the serialization API is able to write
##   and load JSON; you do not need the JSON API for that.
##
## Apart from those high-level APIs, NimYAML implements a low-level API which
## enables you to process YAML input as data stream which does not need to be
## loaded into RAM completely at once. It consists of the following modules:
##
## * The stream API in `stream <yaml.stream.html>`_ defines the central type for
##   stream processing, ``YamlStream``. It also contains definitions and
##   constructor procs for stream events.
## * The parser API in `parser <yaml.parser.html>`_ gives you direct access to
##   the YAML parser's output.
## * The presenter API in `presenter <yaml/presenter.html>`_ gives you direct
##   access to the presenter, i.e. the module that renders a YAML character
##   stream.
## * The taglib API in `taglib <yaml.taglib.html>`_ provides a data structure
##   for keeping track of YAML tags that are generated by the parser or used in
##   the presenter.
## * The hints API in `hints <yaml.hints.html>`_ provides a simple proc for
##   guessing the type of a scalar value.

import yaml.dom, yaml.hints, yaml.parser, yaml.presenter,
       yaml.serialization, yaml.stream, yaml.taglib, yaml.tojson
export yaml.dom, yaml.hints, yaml.parser, yaml.presenter,
       yaml.serialization, yaml.stream, yaml.taglib, yaml.tojson