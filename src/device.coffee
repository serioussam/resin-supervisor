EventEmitter = require 'events'
gosuper = require './lib/gosuper'

exports.shuttingDown = false
exports.events = new EventEmitter()
exports.reboot = ->
	gosuper.postAsync('/v1/reboot', { json: true })
	.spread (res, body) ->
		if res.statusCode != 202
			throw new Error(body.Error)
		exports.shuttingDown = true
		exports.events.emit('shutdown')
		return body

exports.shutdown = ->
	gosuper.postAsync('/v1/shutdown', { json: true })
	.spread (res, body) ->
		if res.statusCode != 202
			throw new Error(body.Error)
		exports.shuttingDown = true
		exports.events.emit('shutdown')
		return body
