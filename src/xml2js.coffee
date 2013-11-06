sax = require 'sax'
events = require 'events'
builder = require 'xmlbuilder'
bom = require './bom'

# Underscore has a nice function for this, but we try to go without dependencies
isEmpty = (thing) ->
  return typeof thing is "object" && thing? && Object.keys(thing).length is 0

exports.defaults =
  "0.1":
    explicitCharkey: false
    trim: true
    # normalize implicates trimming, just so you know
    normalize: true
    # normalize tag names to lower case
    normalizeTags: false
    # set default attribute object key
    attrkey: "@"
    # set default char object key
    charkey: "#"
    # always put child nodes in an array
    explicitArray: false
    # ignore all attributes regardless
    ignoreAttrs: false
    # merge attributes and child elements onto parent object.  this may
    # cause collisions.
    mergeAttrs: false
    explicitRoot: false
    validator: null
    xmlns : false
    # fold children elements into dedicated property (works only in 0.2)
    explicitChildren: false
    childkey: '@@'
    charsAsChildren: false
    # callbacks are async? not in 0.1 mode
    async: false
    strict: true

  "0.2":
    explicitCharkey: false
    trim: false
    normalize: false
    normalizeTags: false
    attrkey: "$"
    charkey: "_"
    explicitArray: true
    ignoreAttrs: false
    mergeAttrs: false
    explicitRoot: true
    validator: null
    xmlns : false
    explicitChildren: false
    childkey: '$$'
    charsAsChildren: false
    # not async in 0.2 mode either
    async: false
    strict: true
    # xml building options
    rootName: 'root'
    xmldec: {'version': '1.0', 'encoding': 'UTF-8', 'standalone': true}
    doctype: null
    renderOpts: { 'pretty': true, 'indent': '  ', 'newline': '\n' }

class exports.ValidationError extends Error
  constructor: (message) ->
    @message = message

class exports.Builder
  constructor: (opts) ->
    # copy this versions default options
    @options = {}
    @options[key] = value for own key, value of exports.defaults["0.2"]
    # overwrite them with the specified options, if any
    @options[key] = value for own key, value of opts

  buildObject: (rootObj) ->
    attrkey = @options.attrkey
    charkey = @options.charkey

    # If there is a sane-looking first element to use as the root,
    # and the user hasn't specified a non-default rootName,
    if ( Object.keys(rootObj).length is 1 ) and ( @options.rootName == exports.defaults['0.2'].rootName )
      # we'll take the first element as the root element
      rootName = Object.keys(rootObj)[0]
      rootObj = rootObj[rootName]
    else
      # otherwise we'll use whatever they've set, or the default
      rootName = @options.rootName

    render = (element, obj) ->
      if typeof obj isnt 'object'
        # single element, just append it as text
        element.txt obj
      else
        for own key, child of obj
          # Case #1 Attribute
          if key is attrkey
            if typeof child is "object"
              # Inserts tag attributes
              for attr, value of child
                element = element.att(attr, value)

          # Case #2 Char data (CDATA, etc.)
          else if key is charkey
            element = element.txt(child)

          # Case #3 Array data
          else if typeof child is 'object' and child?.constructor? and child?.constructor?.name? and child?.constructor?.name is 'Array'
            for own index, entry of child
              if typeof entry is 'string'
                element = element.ele(key, entry).up()
              else
                element = arguments.callee(element.ele(key), entry).up()

          # Case #4 Objects
          else if typeof child is "object"
            element = arguments.callee(element.ele(key), child).up()

          # Case #5 String and remaining types
          else
            element = element.ele(key, child.toString()).up()

      element

    rootElement = builder.create(rootName, @options.xmldec, @options.doctype)

    render(rootElement, rootObj).end(@options.renderOpts)

class exports.Parser extends events.EventEmitter
  constructor: (opts) ->
    # if this was called without 'new', create an instance with new and return
    return new exports.Parser opts unless @ instanceof exports.Parser
    # copy this versions default options
    @options = {}
    @options[key] = value for own key, value of exports.defaults["0.2"]
    # overwrite them with the specified options, if any
    @options[key] = value for own key, value of opts
    # define the key used for namespaces
    if @options.xmlns
      @options.xmlnskey = @options.attrkey + "ns"

    @reset()

  reset: =>
    # remove all previous listeners for events, to prevent event listener
    # accumulation
    @removeAllListeners()
    # make the SAX parser. tried trim and normalize, but they are not
    # very helpful
    @saxParser = sax.parser @options.strict, {
      trim: false,
      normalize: false,
      xmlns: @options.xmlns
    }

    # emit one error event if the sax parser fails. this is mostly a hack, but
    # the sax parser isn't state of the art either.
    err = false
    @saxParser.onerror = (error) =>
      if ! err
        err = true
        @emit "error", error

    # always use the '#' key, even if there are no subkeys
    # setting this property by and is deprecated, yet still supported.
    # better pass it as explicitCharkey option to the constructor
    @EXPLICIT_CHARKEY = @options.explicitCharkey
    @resultObject = null
    stack = []
    # aliases, so we don't have to type so much
    attrkey = @options.attrkey
    charkey = @options.charkey

    @saxParser.onopentag = (node) =>
      obj = {}
      obj[charkey] = ""
      unless @options.ignoreAttrs
        for own key of node.attributes
          if attrkey not of obj and not @options.mergeAttrs
            obj[attrkey] = {}
          if @options.mergeAttrs
            obj[key] = node.attributes[key]
          else
            obj[attrkey][key] = node.attributes[key]

      # need a place to store the node name
      obj["#name"] = if @options.normalizeTags then node.name.toLowerCase() else node.name
      if (@options.xmlns)
        obj[@options.xmlnskey] = {uri: node.uri, local: node.local}
      stack.push obj

    @saxParser.onclosetag = =>
      obj = stack.pop()
      nodeName = obj["#name"]
      delete obj["#name"]

      cdata = obj.cdata
      delete obj.cdata

      s = stack[stack.length - 1]
      # remove the '#' key altogether if it's blank
      if obj[charkey].match(/^\s*$/) and not cdata
        emptyStr = obj[charkey]
        delete obj[charkey]
      else
        obj[charkey] = obj[charkey].trim() if @options.trim
        obj[charkey] = obj[charkey].replace(/\s{2,}/g, " ").trim() if @options.normalize
        # also do away with '#' key altogether, if there's no subkeys
        # unless EXPLICIT_CHARKEY is set
        if Object.keys(obj).length == 1 and charkey of obj and not @EXPLICIT_CHARKEY
          obj = obj[charkey]

      if (isEmpty obj)
        obj = if @options.emptyTag != undefined
          @options.emptyTag
        else
          emptyStr

      if @options.validator?
        xpath = "/" + (node["#name"] for node in stack).concat(nodeName).join("/")
        try
          obj = @options.validator(xpath, s and s[nodeName], obj)
        catch err
          @emit "error", err

      # put children into <childkey> property and unfold chars if necessary
      if @options.explicitChildren and not @options.mergeAttrs and typeof obj is 'object'
        node = {}
        # separate attributes
        if @options.attrkey of obj
          node[@options.attrkey] = obj[@options.attrkey]
          delete obj[@options.attrkey]
        # separate char data
        if not @options.charsAsChildren and @options.charkey of obj
          node[@options.charkey] = obj[@options.charkey]
          delete obj[@options.charkey]

        if Object.getOwnPropertyNames(obj).length > 0
          node[@options.childkey] = obj

        obj = node

      # check whether we closed all the open tags
      if stack.length > 0
        if not @options.explicitArray
          if nodeName not of s
            s[nodeName] = obj
          else if s[nodeName] instanceof Array
            s[nodeName].push obj
          else
            old = s[nodeName]
            s[nodeName] = [old]
            s[nodeName].push obj
        else
          if not (s[nodeName] instanceof Array)
            s[nodeName] = []
          s[nodeName].push obj
      else
        # if explicitRoot was specified, wrap stuff in the root tag name
        if @options.explicitRoot
          # avoid circular references
          old = obj
          obj = {}
          obj[nodeName] = old

        @resultObject = obj
        @emit "end", @resultObject

    ontext = (text) =>
      s = stack[stack.length - 1]
      if s
        s[charkey] += text
        s

    @saxParser.ontext = ontext
    @saxParser.oncdata = (text) =>
      s = ontext text
      if s
        s.cdata = true

  parseString: (str, cb) =>
    if cb? and typeof cb is "function"
      @on "end", (result) ->
        @reset()
        if @options.async
          process.nextTick ->
            cb null, result
        else
          cb null, result
      @on "error", (err) ->
        @reset()
        if @options.async
          process.nextTick ->
            cb err
        else
          cb err

    if str.toString().trim() is ''
      @emit "end", null
      return true

    @saxParser.write bom.stripBOM str.toString()

exports.parseString = (str, a, b) ->
  # let's determine what we got as arguments
  if b?
    if typeof b == 'function'
      cb = b
    if typeof a == 'object'
      options = a
  else
    # well, b is not set, so a has to be a callback
    if typeof a == 'function'
      cb = a
    # and options should be empty - default
    options = {}

  # the rest is super-easy
  parser = new exports.Parser options
  parser.parseString str, cb
