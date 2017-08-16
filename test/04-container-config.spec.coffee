prepare = require './lib/prepare'
Promise = require 'bluebird'
m = require 'mochainon'

{ expect } = m.chai

containerConfig = require '../src/lib/container-config'
describe 'containerConfig', ->
	before ->
		prepare()

	it 'extends environment variables properly', ->
		extendEnvVarsOpts = {
			uuid: '1234'
			appId: 23
			appName: 'awesomeApp'
			commit: 'abcdef'
			buildId: 'abcd'
			name: 'awesomeDevice'
			version: 'v1.0.0'
			deviceType: 'raspberry-pie'
			osVersion: 'Resin OS 2.0.2'
			serviceName: 'serviceName'
		}
		env = {
			FOO: 'bar'
			A_VARIABLE: 'ITS_VALUE'
		}
		extendedEnv = containerConfig.extendEnvVars(env, extendEnvVarsOpts)

		expect(extendedEnv).to.deep.equal({
			FOO: 'bar'
			A_VARIABLE: 'ITS_VALUE'
			RESIN_APP_ID: '23'
			RESIN_APP_NAME: 'awesomeApp'
			RESIN_APP_RELEASE: 'abcdef'
			RESIN_APP_BUILD: 'abcd'
			RESIN_DEVICE_UUID: '1234'
			RESIN_DEVICE_NAME_AT_INIT: 'awesomeDevice'
			RESIN_DEVICE_TYPE: 'raspberry-pie'
			RESIN_HOST_OS_VERSION: 'Resin OS 2.0.2'
			RESIN_SERVICE_NAME: 'serviceName'
			RESIN_SUPERVISOR_VERSION: 'v1.0.0'
			RESIN_APP_LOCK_PATH: '/tmp/resin/resin-updates.lock'
			RESIN_SERVICE_KILL_ME_PATH: '/tmp/resin-service/resin-kill-me'
			RESIN: '1'
			USER: 'root'
		})

	it 'returns the correct default bind mounts', ->
		binds = containerConfig.defaultBinds('1234', '567')
		expect(binds).to.deep.equal([
			'/tmp/resin-supervisor/1234:/tmp/resin'
			'/tmp/resin-supervisor/services/1234/567:/tmp/resin-service'
		])
