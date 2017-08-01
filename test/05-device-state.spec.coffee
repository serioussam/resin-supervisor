Promise = require 'bluebird'
m = require 'mochainon'

{ stub } = m.sinon
m.chai.use(require('chai-events'))
{ expect } = m.chai

prepare = require './lib/prepare'
DeviceState = require '../src/device-state'
DB = require('../src/db')
Config = require('../src/config')

containerConfig = require '../src/lib/container-config'

testTarget1 = {
	local: {
		name: 'aDevice'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '256'
			'RESIN_HOST_LOG_TO_DISPLAY': '0'
		}
		apps:[
			{
				appId: '1234'
				name: 'superapp'
				commit: 'abcdef'
				buildId: '1'
				services: [
					{
						appId: '1234'
						serviceId: '23'
						containerId: '12345'
						config: {}
						serviceName: 'someservice'
						image: 'registry2.resin.io/superapp/abcdef:latest'
						labels: {
							'io.resin.something': 'bar'
						}
						environment: {
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						running: true
					}
				]
				volumes: {}
				networks: {}
				config: {
					'RESIN_HOST_CONFIG_gpu_mem': '256'
					'RESIN_HOST_LOG_TO_DISPLAY': '0'
				}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

testTarget2 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc'
						config: {}
						environment: {
							'FOO': 'bar'
						}
						labels: {}
					},
					{
						serviceId: '24'
						serviceName: 'anotherService'
						containerId: '12346'
						image: 'registry2.resin.io/superapp/afaff'
						config: {}
						environment: {
							'FOO': 'bro'
						}
						labels: {}
					}
				]
			}
		]
	}
	dependent: { apps: [], devices: [] }
}
testTargetWithDefaults2 = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						appId: '1234'
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc:latest'
						config: {}
						environment: {
							'FOO': 'bar'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						volumes: [
							'/resin-data/1234/services/23:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						labels: {}
						running: true
					},
					{
						appId: '1234'
						serviceId: '24'
						serviceName: 'anotherService'
						containerId: '12346'
						image: 'registry2.resin.io/superapp/afaff:latest'
						config: {}
						environment: {
							'FOO': 'bro'
							'ADDITIONAL_ENV_VAR': 'foo'
						}
						volumes: [
							'/resin-data/1234/services/24:/data'
							'/tmp/resin-supervisor/1234:/tmp/resin'
						]
						privileged: false
						restartPolicy: Name: 'unless-stopped'
						labels: {}
						running: true
					}
				]
				volumes: {}
				networks: {}
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

testTargetInvalid = {
	local: {
		name: 'aDeviceWithDifferentName'
		config: {
			'RESIN_HOST_CONFIG_gpu_mem': '512'
			'RESIN_HOST_LOG_TO_DISPLAY': '1'
		}
		apps: [
			{
				appId: '1234'
				name: 'superapp'
				commit: 'afafafa'
				buildId: '2'
				config: {}
				services: [
					{
						serviceId: '23'
						serviceName: 'aservice'
						containerId: '12345'
						image: 'registry2.resin.io/superapp/edfabc'
						config: {}
						environment: {
							' FOO': 'bar'
						}
						labels: {}
					},
					{
						serviceId: '24'
						serviceName: 'anotherService'
						containerId: '12346'
						image: 'registry2.resin.io/superapp/afaff'
						config: {}
						environment: {
							'FOO': 'bro'
						}
						labels: {}
					}
				]
			}
		]
	}
	dependent: { apps: [], devices: [] }
}

describe 'deviceState', ->
	before ->
		@timeout(5000)
		prepare()
		@db = new DB()
		@config = new Config({ @db })
		eventTracker = {
			track: console.log
		}
		stub(containerConfig, 'extendEnvVars').callsFake (env) ->
			env['ADDITIONAL_ENV_VAR'] = 'foo'
			return env
		@deviceState = new DeviceState({ @db, @config, eventTracker })
		@db.init()
		.then =>
			@config.init()

	after ->
		containerConfig.extendEnvVars.restore()

	it 'loads a target state from an apps.json file and saves it as target state, then returns it', ->
		@deviceState.loadTargetFromFile(process.env.ROOT_MOUNTPOINT + '/apps.json')
		.then =>
			@deviceState.getTarget()
		.then (targetState) ->
			expect(targetState).to.deep.equal(testTarget1)

	it 'emits a change event when a new state is reported', ->
		@deviceState.reportCurrentState({ someStateDiff: 'someValue' })
		expect(@deviceState).to.emit('current-state-change')

	it 'returns the current state'

	it 'writes the target state to the db with some extra defaults', ->
		@deviceState.setTarget(testTarget2)
		.then =>
			@deviceState.getTarget()
		.then (target) ->
			expect(target).to.deep.equal(testTargetWithDefaults2)

	it 'does not allow setting an invalid target state', ->
		promise = @deviceState.setTarget(testTargetInvalid)
		promise.catch(->)
		expect(promise).to.be.rejected

	it 'allows triggering applying the target state', (done) ->
		stub(@deviceState, 'applyTarget')
		@deviceState.triggerApplyTarget({ force: true })
		expect(@deviceState.applyTarget).to.not.be.called
		setTimeout =>
			expect(@deviceState.applyTarget).to.be.calledWith({ force: true })
			@deviceState.applyTarget.restore()
			done()
		, 5

	it 'applies the target state for device config'

	it 'applies the target state for applications'
