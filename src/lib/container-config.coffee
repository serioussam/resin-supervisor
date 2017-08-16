_ = require 'lodash'

exports.extendEnvVars = (env, { uuid, appId, appName, serviceName, commit, buildId, name, version, deviceType, osVersion }) ->
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
		RESIN_SUPERVISOR_VERSION: version
		RESIN_APP_LOCK_PATH: '/tmp/resin/resin-updates.lock'
		RESIN_SERVICE_KILL_ME_PATH: '/tmp/resin-service/resin-kill-me'
		RESIN: '1'
		USER: 'root'
	if env?
		_.defaults(newEnv, env)
	return newEnv

exports.lockPath = (appId) ->
	"/tmp/resin-supervisor/#{appId}"

exports.killmePath = (appId, serviceName) ->
	"/tmp/resin-supervisor/services/#{appId}/#{serviceName}"

exports.defaultBinds = (appId, serviceId) ->
	return [
		"#{exports.lockPath(appId)}:/tmp/resin"
		"#{exports.killmePath(appId, serviceId)}:/tmp/resin-service"
	]