constants = require './constants'
_ = require 'lodash'

exports.extendEnvVars = (env, { uuid, appId, appName, serviceName, commit, buildId, listenPort, name, apiSecret, deviceApiKey, version, deviceType, osVersion }) ->
	host = '127.0.0.1'
	newEnv =
		RESIN_APP_ID: appId.toString()
		RESIN_APP_NAME: appName
		RESIN_APP_RELEASE: commit
		RESIN_APP_BUILD: buildId
		RESIN_SERVICE_NAME: serviceName
		RESIN_DEVICE_UUID: uuid
		RESIN_DEVICE_NAME_AT_INIT: name
		RESIN_DEVICE_TYPE: deviceType
		RESIN_HOST_OS_VERSION: osVersion
		RESIN_SUPERVISOR_ADDRESS: "http://#{host}:#{listenPort}"
		RESIN_SUPERVISOR_HOST: host
		RESIN_SUPERVISOR_PORT: listenPort.toString()
		RESIN_SUPERVISOR_API_KEY: apiSecret
		RESIN_SUPERVISOR_VERSION: version
		RESIN_API_KEY: deviceApiKey
		RESIN: '1'
		USER: 'root'
	if env?
		_.defaults(newEnv, env)
	return newEnv

exports.getDataPath = getDataPath = (appId, serviceId) ->
	p = "#{constants.dataPath}/#{appId}"
	if serviceId?
		p += "/services/#{serviceId}"
	return p

exports.defaultBinds = (appId, serviceId) ->
	binds = [
		getDataPath(appId, serviceId) + ':/data'
		"/tmp/resin-supervisor/#{appId}:/tmp/resin"
	]
	return binds
