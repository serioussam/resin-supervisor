_ = require 'lodash'

exports.appStateToDB = (app) ->
	app.volumes ?= {}
	app.services ?= []
	app.config ?= {}
	app.networks ?= {}

	dbApp = {
		appId: app.appId
		commit: app.commit
		name: app.name
		buildId: app.buildId
		config: JSON.stringify(app.config)
		services: JSON.stringify(app.services)
		networks: JSON.stringify(app.networks)
		volumes: JSON.stringify(app.volumes)
	}
	return dbApp

exports.dependentAppStateToDB = (app) ->
	app.environment ?= {}
	app.config ?= {}
	dbApp = {
		appId: app.appId
		name: app.name
		commit: app.commit
		buildId: app.buildId
		parentApp: app.parentApp
		image: app.image
		config: JSON.stringify(app.config)
		environment: JSON.stringify(app.environment)
	}
	return dbApp

exports.appDBToState = (app) ->
	outApp = {
		appId: app.appId
		name: app.name
		commit: app.commit
		config: JSON.parse(app.config)
		services: JSON.parse(app.services)
		networks: JSON.parse(app.networks)
		volumes: JSON.parse(app.volumes)
	}
	return outApp

exports.dependentAppDBToState = (app) ->
	outApp = {
		appId: app.appId
		name: app.name
		commit: app.commit
		buildId: app.buildId
		image: app.image
		config: JSON.parse(app.config)
		environment: JSON.parse(app.environment)
		parentApp: app.parentApp
	}
	return outApp

exports.dependentDeviceTargetStateToDB = (device) ->
	apps = JSON.stringify(device.apps ? {})
	outDevice = {
		uuid: device.uuid
		name: device.name
		apps
	}
	return outDevice

exports.dependentDeviceTargetDBToState = (device) ->
	outDevice = {
		uuid: device.uuid
		name: device.name
		apps: JSON.parse(device.apps)
	}
exports.envArrayToObject = (env) ->
	# env is an array of strings that say 'key=value'
	_(env)
	.invokeMap('split', '=')
	.fromPairs()
	.value()

# Construct a restart policy based on its name and maximumRetryCount.
# Both arguments are optional, and the default policy is "always".
#
# Throws exception if an invalid policy name is given.
# Returns a RestartPolicy { Name, MaximumRetryCount } object
createRestartPolicy = ({ name, maximumRetryCount }) ->
	if not name?
		name = 'unless-stopped'
	if not (name in validRestartPolicies)
		throw new Error("Invalid restart policy: #{name}")
	policy = { Name: name }
	if name is 'on-failure' and maximumRetryCount?
		policy.MaximumRetryCount = maximumRetryCount
	return policy

exports.serviceToContainerConfig = (service, imageInfo) ->
	if imageInfo?.Config?.Cmd
		cmd = imageInfo.Config.Cmd
	else
		cmd = [ '/bin/bash', '-c', '/start' ]

	ports = {}
	portBindings = {}

	if service.ports?
		_.forEach service.ports, (port) ->
			# TODO: map ports for any of the possible formats "container:host/protocol", port ranges, etc.
			ports[port + '/tcp'] = {}
			portBindings[port + '/tcp'] = [ HostPort: port ]

	if service.expose?
		_.forEach service.expose, (port) ->
			ports[port + '/tcp'] = {}

	labels = _.clone(service.labels)
	labels['io.resin.serviceId'] = service.serviceId
	labels['io.resin.serviceName'] = service.Name
	labels['io.resin.containerId'] = service.containerId
	labels['io.resin.config'] = JSON.stringify(service.config)
	labels['io.resin.buildId'] = service.buildId
	volumes = _.omit service.volumes, (vol) ->
		/:/.test(vol)
	binds = _.filter service.volumes, (vol) ->
		/:/.test(vol)

	restartPolicy = createRestartPolicy({ name: service.config['RESIN_APP_RESTART_POLICY'], maximumRetryCount: service.config['RESIN_APP_RESTART_RETRIES'] })

	return {
		Image: service.image
		Cmd: cmd
		Tty: true
		Volumes: volumes
		Env: _.map service.environment, (v, k) -> k + '=' + v
		ExposedPorts: ports
		HostConfig:
			Privileged: true
			NetworkMode: 'host'
			PortBindings: portBindings
			Binds: binds
			RestartPolicy: restartPolicy
	}
