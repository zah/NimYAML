#            NimYAML - YAML implementation in Nim
#        (c) Copyright 2015 Felix Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## This module provides facilities to generate and interpret
## `YAML <http://yaml.org>`_ character streams. All primitive operations on
## data objects use a `YamlStream <#YamlStream>`_ either as source or as
## output. Because this stream is implemented as iterator, it is possible to
## process YAML input and output sequentially, i.e. without loading the
## processed data structure completely into RAM. This supports the processing of
## large data structures.
##
## As YAML is a strict superset of `JSON <http://json.org>`_, JSON input is
## automatically supported. Additionally, there is functionality available to
## convert any YAML stream into JSON. While JSON is less readable than YAML,
## this enhances interoperability with other languages.

import streams, unicode, lexbase, tables, strutils, json, hashes, queues, macros
export streams, tables, json

when defined(yamlDebug):
  import terminal

type
    TypeHint* = enum
        ## A type hint can be computed from scalar content and tells you what
        ## NimYAML thinks the scalar's type is. It is generated by
        ## `guessType <#guessType,string,TypeHint>`_ The first matching RegEx
        ## in the following table will be the type hint of a scalar string.
        ##
        ## You can use it to determine the type of YAML scalars that have a '?'
        ## non-specific tag, but using this feature is completely optional.
        ##
        ## ================== =========================
        ## Name               RegEx
        ## ================== =========================
        ## ``yTypeInteger``   ``0 | -? [1-9] [0-9]*``
        ## ``yTypeFloat``     ``-? [1-9] ( \. [0-9]* [1-9] )? ( e [-+] [1-9] [0-9]* )?``
        ## ``yTypeFloatInf``  ``-? \. (inf | Inf | INF)``
        ## ``yTypeFloatNaN``  ``-? \. (nan | NaN | NAN)``
        ## ``yTypeBoolTrue``  ``y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON``
        ## ``yTypeBoolFalse`` ``n|N|no|No|NO|false|False|FALSE|off|Off|OFF``
        ## ``yTypeNull``      ``~ | null | Null | NULL``
        ## ``yTypeUnknown``   ``*``
        ## ================== =========================
        yTypeInteger, yTypeFloat, yTypeFloatInf, yTypeFloatNaN, yTypeBoolTrue,
        yTypeBoolFalse, yTypeNull, yTypeUnknown
    
    YamlStreamEventKind* = enum
        ## Kinds of YAML events that may occur in an ``YamlStream``. Event kinds
        ## are discussed in ``YamlStreamEvent``.
        yamlStartDocument, yamlEndDocument, yamlStartMap, yamlEndMap,
        yamlStartSequence, yamlEndSequence, yamlScalar, yamlAlias
    
    TagId* = distinct int ## \
        ## A ``TagId`` identifies a tag URI, like for example 
        ## ``"tag:yaml.org,2002:str"``. The URI corresponding to a ``TagId`` can
        ## be queried from the `TagLibrary <#TagLibrary>`_ which was
        ## used to create this ``TagId``; e.g. when you parse a YAML character
        ## stream, the ``TagLibrary`` of the parser is the one which generates
        ## the resulting ``TagId`` s.
        ##
        ## URI strings are mapped to ``TagId`` s for efficiency  reasons (you
        ## do not need to compare strings every time) and to be able to
        ## discover unknown tag URIs early in the parsing process.
    
    AnchorId* = distinct int ## \
        ## An ``AnchorId`` identifies an anchor in the current document. It
        ## becomes invalid as soon as the current document scope is invalidated
        ## (for example, because the parser yielded a ``yamlEndDocument``
        ## event). ``AnchorId`` s exists because of efficiency, much like
        ## ``TagId`` s. The actual anchor name is a presentation detail and
        ## cannot be queried by the user.
    
    YamlStreamEvent* = object
        ## An element from a `YamlStream <#YamlStream>`_. Events that start an
        ## object (``yamlStartMap``, ``yamlStartSequence``, ``yamlScalar``) have
        ## an optional anchor and a tag associated with them. The anchor will be
        ## set to ``yAnchorNone`` if it doesn't exist.
        ## 
        ## A non-existing tag in the YAML character stream will be resolved to 
        ## the non-specific tags ``?`` or ``!`` according to the YAML
        ## specification. These are by convention mapped to the ``TagId`` s
        ## ``yTagQuestionMark`` and ``yTagExclamationMark`` respectively.
        ## Mapping is done by a `TagLibrary <#TagLibrary>`_.
        case kind*: YamlStreamEventKind
        of yamlStartMap:
            mapAnchor* : AnchorId
            mapTag*    : TagId
        of yamlStartSequence:
            seqAnchor* : AnchorId
            seqTag*    : TagId
        of yamlScalar:
            scalarAnchor* : AnchorId
            scalarTag*    : TagId
            scalarContent*: string # may not be nil (but empty)
        of yamlEndMap, yamlEndSequence, yamlStartDocument, yamlEndDocument:
            discard
        of yamlAlias:
            aliasTarget* : AnchorId
    
    YamlStream* = iterator(): YamlStreamEvent ## \
        ## A ``YamlStream`` is an iterator that yields a well-formed stream of
        ## ``YamlStreamEvents``. Well-formed means that every ``yamlStartMap``
        ## is terminated by a ``yamlEndMap``, every ``yamlStartSequence`` is
        ## terminated by a ``yamlEndSequence`` and every ``yamlStartDocument``
        ## is terminated by a ``yamlEndDocument``. Moreover, every emitted map
        ## has an even number of children.
        ##
        ## The creator of a ``YamlStream`` is responsible for it being
        ## well-formed. A user of the stream may assume that it is well-formed
        ## and is not required to check for it. The procs in this module will
        ## always yield a well-formed ``YamlStream`` and expect it to be
        ## well-formed if it's an input.
    
    TagLibrary* = ref object
        ## A ``TagLibrary`` maps tag URIs to ``TagId`` s.
        ##
        ## Three tag libraries are provided with this module:
        ## `failsafeTagLibrary <#failsafeTagLibrary>`_, 
        ## `coreTagLibrary <#coreTagLibrary>`_, and 
        ## `extendedTagLibrary <#extendedTagLibrary>`_.
        ##
        ## When `YamlParser <#YamlParser>`_ encounters tags not existing in the
        ## tag library, it will use
        ## `registerTagUri <#registerTagUri,TagLibrary,string,TagId>`_ to add
        ## the tag to the library.
        ##
        ## You can base your tag library on common tag libraries by initializing
        ## them with `initFailsafeTagLibrary <#initFailsafeTagLibrary>`_,
        ## `initCoreTagLibrary <#initCoreTagLibrary>`_ or
        ## `initExtendedTagLibrary <#initExtendedTagLibrary>`_.
        tags*: Table[string, TagId]
        nextCustomTagId*: TagId
        secondaryPrefix*: string
    
    
    WarningCallback* = proc(line, column: int, lineContent: string,
                                message: string)
        ## Callback for parser warnings. Currently, this callback may be called
        ## on two occasions while parsing a YAML document stream:
        ##
        ## - If the version number in the ``%YAML`` directive does not match
        ##   ``1.2``.
        ## - If there is an unknown directive encountered.
    
    YamlParser* = ref object
        ## A parser object. Retains its ``TagLibrary`` across calls to
        ## `parse <#parse,YamlParser,Stream,YamlStream>`_. Can be used
        ## to access anchor names while parsing a YAML character stream, but
        ## only until the document goes out of scope (i.e. until
        ## ``yamlEndDocument`` is yielded).
        tagLib: TagLibrary
        anchors: OrderedTable[string, AnchorId]
        callback: WarningCallback
        lexer: BaseLexer
        tokenstart: int
        
    PresentationStyle* = enum
        ## Different styles for YAML character stream output.
        ##
        ## - ``ypsMinimal``: Single-line flow-only output which tries to
        ##   use as few characters as possible.
        ## - ``ypsCanonical``: Canonical YAML output. Writes all tags except
        ##   for the non-specific tags ``?`` and ``!``, uses flow style, quotes
        ##   all string scalars.
        ## - ``ypsDefault``: Tries to be as human-readable as possible. Uses
        ##   block style by default, but tries to condense maps and sequences
        ##   which only contain scalar nodes into a single line using flow
        ##   style.
        ## - ``ypsJson``: Omits the ``%YAML`` directive and the ``---``
        ##   marker. Uses flow style. Flattens anchors and aliases, omits tags.
        ##   Output will be parseable as JSON. ``YamlStream`` to dump may only
        ##   contain one document.
        ## - ``ypsBlockOnly``: Formats all output in block style, does not use
        ##   flow style at all.
        psMinimal, psCanonical, psDefault, psJson, psBlockOnly
    
    YamlLoadingError* = object of Exception
        ## Base class for all exceptions that may be raised during the process
        ## of loading a YAML character stream. 
        line*: int ## line number (1-based) where the error was encountered
        column*: int ## \
            ## column number (1-based) where the error was encountered
        lineContent*: string ## \
            ## content of the line where the error was encountered. Includes a
            ## second line with a marker ``^`` at the position where the error
            ## was encountered.
    
    YamlParserError* = object of YamlLoadingError
        ## A parser error is raised if the character stream that is parsed is
        ## not a valid YAML character stream. This stream cannot and will not be
        ## parsed wholly nor partially and all events that have been emitted by
        ## the YamlStream the parser provides should be discarded.
        ##
        ## A character stream is invalid YAML if and only if at least one of the
        ## following conditions apply:
        ##
        ## - There are invalid characters in an element whose contents is
        ##   restricted to a limited set of characters. For example, there are
        ##   characters in a tag URI which are not valid URI characters.
        ## - An element has invalid indentation. This can happen for example if
        ##   a block list element indicated by ``"- "`` is less indented than
        ##   the element in the previous line, but there is no block sequence
        ##   list open at the same indentation level. 
        ## - The YAML structure is invalid. For example, an explicit block map
        ##   indicated by ``"? "`` and ``": "`` may not suddenly have a block
        ##   sequence item (``"- "``) at the same indentation level. Another
        ##   possible violation is closing a flow style object with the wrong
        ##   closing character (``}``, ``]``) or not closing it at all.
        ## - A custom tag shorthand is used that has not previously been 
        ##   declared with a ``%TAG`` directive.
        ## - Multiple tags or anchors are defined for the same node.
        ## - An alias is used which does not map to any anchor that has
        ##   previously been declared in the same document.
        ## - An alias has a tag or anchor associated with it.
        ##
        ## Some elements in this list are vague. For a detailed description of a
        ## valid YAML character stream, see the YAML specification.
    
    YamlPresenterJsonError* = object of Exception
        ## Exception that may be raised by the YAML presenter when it is
        ## instructed to output JSON, but is unable to do so. This may occur if:
        ##
        ## - The given `YamlStream <#YamlStream>`_ contains a map which has any
        ##   non-scalar type as key.
        ## - Any float scalar bears a ``NaN`` or positive/negative infinity
        ##   value
    
    YamlPresenterOutputError* = object of Exception
        ## Exception that may be raised by the YAML presenter. This occurs if
        ## writing character data to the output stream raises any exception.
        ## The error that has occurred is available from ``parent``.
    
    YamlPresenterStreamError* = object of Exception
        ## Exception that may be raised by the YAML presenter. This occurs if
        ## an exception is raised while retrieving the next item from a
        ## `YamlStream <#YamlStream>`_. The error that has occurred is
        ## available from ``parent``.
    
    YamlConstructionError* = object of YamlLoadingError
        ## Exception that may be raised when constructing data objects from a
        ## `YamlStream <#YamlStream>`_. The fields ``line``, ``column`` and
        ## ``lineContent`` are only available if the costructing proc also does
        ## parsing, because otherwise this information is not available to the
        ## costruction proc.
    
    YamlConstructionStreamError* = object of YamlLoadingError
        ## Exception that may be raised by a constructor if the input
        ## `YamlStream <#YamlStream>`_ raises an error. The error that has
        ## occurred is available from ``parent``.
const
    # failsafe schema

    yTagExclamationMark*: TagId = 0.TagId ## ``!`` non-specific tag
    yTagQuestionMark*   : TagId = 1.TagId ## ``?`` non-specific tag
    yTagString*         : TagId = 2.TagId ## \
        ## `!!str <http://yaml.org/type/str.html >`_ tag
    yTagSequence*       : TagId = 3.TagId ## \
        ## `!!seq <http://yaml.org/type/seq.html>`_ tag
    yTagMap*            : TagId = 4.TagId ## \
        ## `!!map <http://yaml.org/type/map.html>`_ tag
    
    # json & core schema
    
    yTagNull*    : TagId = 5.TagId ## \
        ## `!!null <http://yaml.org/type/null.html>`_ tag
    yTagBoolean* : TagId = 6.TagId ## \
        ## `!!bool <http://yaml.org/type/bool.html>`_ tag
    yTagInteger* : TagId = 7.TagId ## \
        ## `!!int <http://yaml.org/type/int.html>`_ tag
    yTagFloat*   : TagId = 8.TagId ## \
        ## `!!float <http://yaml.org/type/float.html>`_ tag
    
    # other language-independent YAML types (from http://yaml.org/type/ )
    
    yTagOrderedMap* : TagId = 9.TagId  ## \
        ## `!!omap <http://yaml.org/type/omap.html>`_ tag
    yTagPairs*      : TagId = 10.TagId ## \
        ## `!!pairs <http://yaml.org/type/pairs.html>`_ tag
    yTagSet*        : TagId = 11.TagId ## \
        ## `!!set <http://yaml.org/type/set.html>`_ tag
    yTagBinary*     : TagId = 12.TagId ## \
        ## `!!binary <http://yaml.org/type/binary.html>`_ tag
    yTagMerge*      : TagId = 13.TagId ## \
        ## `!!merge <http://yaml.org/type/merge.html>`_ tag
    yTagTimestamp*  : TagId = 14.TagId ## \
        ## `!!timestamp <http://yaml.org/type/timestamp.html>`_ tag
    yTagValue*      : TagId = 15.TagId ## \
        ## `!!value <http://yaml.org/type/value.html>`_ tag
    yTagYaml*       : TagId = 16.TagId ## \
        ## `!!yaml <http://yaml.org/type/yaml.html>`_ tag
    
    yFirstCustomTagId* : TagId = 1000.TagId ## \
        ## The first ``TagId`` which should be assigned to an URI that does not
        ## exist in the ``YamlTagLibrary`` which is used for parsing.
    
    yAnchorNone*: AnchorId = (-1).AnchorId ## \
        ## yielded when no anchor was defined for a YAML node
    
    yamlTagRepositoryPrefix* = "tag:yaml.org,2002:"

# interface

proc `==`*(left: YamlStreamEvent, right: YamlStreamEvent): bool {.raises: [].}
    ## compares all existing fields of the given items
    
proc `$`*(event: YamlStreamEvent): string {.raises: [].}
    ## outputs a human-readable string describing the given event

proc startDocEvent*(): YamlStreamEvent {.inline, raises: [].}
proc endDocEvent*(): YamlStreamEvent {.inline, raises: [].}
proc startMapEvent*(tag: TagId = yTagQuestionMark,
                    anchor: AnchorId = yAnchorNone):
                    YamlStreamEvent {.inline, raises: [].}
proc endMapEvent*(): YamlStreamEvent {.inline, raises: [].}
proc startSeqEvent*(tag: TagId = yTagQuestionMark,
                    anchor: AnchorId = yAnchorNone):
                    YamlStreamEvent {.inline, raises: [].}
proc endSeqEvent*(): YamlStreamEvent {.inline, raises: [].}
proc scalarEvent*(content: string = "", tag: TagId = yTagQuestionMark,
                  anchor: AnchorId = yAnchorNone):
                  YamlStreamEvent {.inline, raises: [].}
proc aliasEvent*(anchor: AnchorId): YamlStreamEvent {.inline, raises: [].}

proc `==`*(left, right: TagId): bool {.borrow.}
proc `$`*(id: TagId): string
proc hash*(id: TagId): Hash {.borrow.}

proc `==`*(left, right: AnchorId): bool {.borrow.}
proc `$`*(id: AnchorId): string {.borrow.}
proc hash*(id: AnchorId): Hash {.borrow.}

proc initTagLibrary*(): TagLibrary {.raises: [].}
    ## initializes the ``tags`` table and sets ``nextCustomTagId`` to
    ## ``yFirstCustomTagId``.

proc registerUri*(tagLib: TagLibrary, uri: string): TagId {.raises: [].}
    ## registers a custom tag URI with a ``TagLibrary``. The URI will get
    ## the ``TagId`` ``nextCustomTagId``, which will be incremented.
    
proc uri*(tagLib: TagLibrary, id: TagId): string {.raises: [KeyError].}
    ## retrieve the URI a ``TagId`` maps to.

# these should be consts, but the Nim VM still has problems handling tables
# properly, so we use let instead.

proc initFailsafeTagLibrary*(): TagLibrary {.raises: [].}
    ## Contains only:
    ## - ``!``
    ## - ``?``
    ## - ``!!str``
    ## - ``!!map``
    ## - ``!!seq``
proc initCoreTagLibrary*(): TagLibrary {.raises: [].}
    ## Contains everything in ``initFailsafeTagLibrary`` plus:
    ## - ``!!null``
    ## - ``!!bool``
    ## - ``!!int``
    ## - ``!!float``
proc initExtendedTagLibrary*(): TagLibrary {.raises: [].}
    ## Contains everything from ``initCoreTagLibrary`` plus:
    ## - ``!!omap``
    ## - ``!!pairs``
    ## - ``!!set``
    ## - ``!!binary``
    ## - ``!!merge``
    ## - ``!!timestamp``
    ## - ``!!value``
    ## - ``!!yaml``

proc guessType*(scalar: string): TypeHint {.raises: [].}

proc newYamlParser*(tagLib: TagLibrary = initExtendedTagLibrary(),
                    callback: WarningCallback = nil): YamlParser {.raises: [].}

proc getLineNumber*(p: YamlParser): int {.raises: [].}
proc getColNumber*(p: YamlParser): int {.raises: [].}
proc getLineContent*(p: YamlParser, marker: bool = true): string {.raises: [].}

proc parse*(p: YamlParser, s: Stream):
        YamlStream {.raises: [IOError, YamlParserError].}

proc constructJson*(s: YamlStream): seq[JsonNode]
        {.raises: [YamlConstructionError, YamlConstructionStreamError].}
    ## Construct an in-memory JSON tree from a YAML event stream. The stream may
    ## not contain any tags apart from those in ``coreTagLibrary``. Anchors and
    ## aliases will be resolved. Maps in the input must not contain
    ## non-scalars as keys. Each element of the result represents one document
    ## in the YAML stream.
    ##
    ## **Warning:** The special float values ``[+-]Inf`` and ``NaN`` will be
    ## parsed into Nim's JSON structure without error. However, they cannot be
    ## rendered to a JSON character stream, because these values are not part
    ## of the JSON specification. Nim's JSON implementation currently does not
    ## check for these values and will output invalid JSON when rendering one
    ## of these values into a JSON character stream.

proc loadToJson*(s: Stream): seq[JsonNode]
        {.raises: [IOError, YamlParserError, YamlConstructionError].}
    ## Uses `YamlParser <#YamlParser>`_ and
    ## `constructJson <#constructJson>`_ to construct an in-memory JSON tree
    ## from a YAML character stream.
    
proc present*(s: YamlStream, target: Stream, tagLib: TagLibrary,
              style: PresentationStyle = psDefault,
              indentationStep: int = 2) {.raises: [YamlPresenterJsonError,
                                                   YamlPresenterOutputError,
                                                   YamlPresenterStreamError].}
    ## Convert ``s`` to a YAML character stream and write it to ``target``.
    
proc transform*(input: Stream, output: Stream, style: PresentationStyle,
                indentationStep: int = 2) {.raises: [IOError, YamlParserError,
                                                     YamlPresenterJsonError,
                                                     YamlPresenterOutputError].}
    ## Parser ``input`` as YAML character stream and then dump it to ``output``
    ## while resolving non-specific tags to the ones in the YAML core tag
    ## library.

# implementation

include private.tagLibrary
include private.events
include private.json
include private.presenter
include private.hints
include private.fastparse