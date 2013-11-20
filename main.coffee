http = require('http')
fs = require('fs')
ejs = require('ejs')
socket_io = require('socket.io')
glob = require('glob')
config = null
max_bufsize = null

readConfig = ->
  # config = require('./config')
  if fs.existsSync "./config.json"
    config = JSON.parse(fs.readFileSync('./config.json'))
  if not config
    config =
      port: 8081
  config.port = 8081 unless config.port
  config.files = [] unless config.files
  config.maxBufSize = 50000 unless config.maxBufSize
  max_bufsize = config.maxBufSize
  config

readConfig()

handler = (req, res) ->
  fs.readFile __dirname + '/src/index.html', "utf8", (err, data) ->
    if err
      res.writeHead(500)
      return res.end('Error loading html')

    readConfig().files.map (item) ->
      base = item.path.replace(/\*.*$/, '')
      files = glob.sync(item.path)
      item.logFiles = files.map (v) ->
        { label : v.replace(base, ""), filename : v }

    res.writeHead(200)
    res.end(ejs.render(data,
      config: config
    ))

app = http.createServer(handler)
app.listen(config.port)
console.log("server started : addr = 0.0.0.0, port = #{config.port}")

io = socket_io.listen(app, {log:false})

io.sockets.on 'connection', (socket) ->
  socket.emit('connected')
  watcher = null
  cur_fsize = 0

  socket.on 'openFile', (data) ->
    return if not data.filename?

    fs.stat data.filename, (err, stat) ->
      watcher.close() if watcher
      if err
        console.log(err)
        socket.emit('error', err.toString());
        return

      cur_fsize = stat.size

      start = if stat.size > max_bufsize then stat.size - max_bufsize else 0
      stream = fs.createReadStream(data.filename, {
        start: start
        end: stat.size
      })

      stream.addListener 'error', (err) ->
        socket.emit 'error', err.toString()

      stream.addListener 'data', (fdata) ->
        fdata = fdata.toString('utf-8')
        if (fdata.length > max_bufsize)
          lines = fdata.slice(fdata.indexOf("\n") + 1).split("\n")
        else
          lines = fdata.split("\n")

        socket.emit('initialize', {
          text: lines
          filename: data.filename
        })
        watch_start(data.filename, socket)
        console.log('stated watching:' + data.filename)

  watch_start = (filename, socket) ->
    org_fsize = 0
    watcher = fs.watch filename, (ev) ->
      fs.stat filename, (err, stat) ->
        if err
          console.log(err)
          socket.emit('error', err.toString())
          return
        if cur_fsize > stat.size
          socket.emit('reset', { filename: filename })
          cur_fsize = stat.size
          return

        stream = fs.createReadStream(filename, { start: cur_fsize, end: stat.size})
        org_fsize = cur_fsize
        cur_fsize = stat.size

        stream.addListener 'error', (err) ->
          socket.emit('error', err.toString())
          cur_fsize = org_fsize

        stream.addListener 'data', (fdata) ->
          socket.emit('continue', {
            text: fdata.toString('utf-8').split("\n")
          })
          # cur_fsize = stat.size
