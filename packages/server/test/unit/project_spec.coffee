require("../spec_helper")

path         = require("path")
Promise      = require("bluebird")
Fixtures     = require("../support/helpers/fixtures")
ids          = require("#{root}lib/ids")
api          = require("#{root}lib/api")
user         = require("#{root}lib/user")
cache        = require("#{root}lib/cache")
errors       = require("#{root}lib/errors")
config       = require("#{root}lib/config")
scaffold     = require("#{root}lib/scaffold")
Server       = require("#{root}lib/server")
Project      = require("#{root}lib/project")
Automation   = require("#{root}lib/automation")
settings     = require("#{root}lib/util/settings")
savedState   = require("#{root}lib/saved_state")
git          = require("#{root}lib/util/git")

describe "lib/project", ->
  beforeEach ->
    Fixtures.scaffold()

    @todosPath    = Fixtures.projectPath("todos")
    @idsPath      = Fixtures.projectPath("ids")
    @pristinePath = Fixtures.projectPath("pristine")

    settings.read(@todosPath).then (obj = {}) =>
      {@projectId} = obj

      @config  = config.set({projectName: "project", projectRoot: "/foo/bar"})
      @project = Project(@todosPath)

  afterEach ->
    Fixtures.remove()
    @project?.close()

  it "requires a projectRoot", ->
    fn = -> Project()
    expect(fn).to.throw "Instantiating lib/project requires a projectRoot!"

  it "always resolves the projectRoot to be absolute", ->
    p = Project("../foo/bar")
    expect(p.projectRoot).not.to.eq("../foo/bar")
    expect(p.projectRoot).to.eq(path.resolve("../foo/bar"))

  context "#getConfig", ->
    beforeEach ->
      @sandbox.stub(config, "get").withArgs(@todosPath, {foo: "bar"}).resolves({baz: "quux", integrationFolder: "foo/bar/baz"})
      @sandbox.stub(@project, "determineIsNewProject").withArgs("foo/bar/baz").resolves(false)

    it "calls config.get with projectRoot + options + saved state", ->
      state = savedState(@todosPath)
      @sandbox.stub(state, "get").returns(Promise.resolve({ reporterWidth: 225 }))
      @project.getConfig({foo: "bar"})
      .then (cfg) ->
        expect(cfg).to.deep.eq({
          integrationFolder: "foo/bar/baz"
          isNewProject: false
          baz: "quux"
          state: {
            reporterWidth: 225
          }
        })

    it "resolves if cfg is already set", ->
      @project.cfg = {foo: "bar"}

      @project.getConfig()
      .then (cfg) ->
        expect(cfg).to.deep.eq({foo: "bar", state: {}})

  context "#open", ->
    beforeEach ->
      @sandbox.stub(@project, "watchSettingsAndStartWebsockets").resolves()
      @sandbox.stub(@project, "watchSupportFile").resolves()
      @sandbox.stub(@project, "scaffold").resolves()
      @sandbox.stub(@project, "getConfig").resolves(@config)
      @sandbox.stub(Server.prototype, "open").resolves()

    it "calls #watchSettingsAndStartWebsockets with options + config", ->
      opts = {changeEvents: false, onAutomationRequest: ->}
      @project.cfg = {}
      @project.open(opts).then =>
        expect(@project.watchSettingsAndStartWebsockets).to.be.calledWith(opts, @project.cfg)

    it "calls #scaffold with server config", ->
      @project.open().then =>
        expect(@project.scaffold).to.be.calledWith(@config)

    it "calls #watchSupportFile with server config when scaffolding is finished", ->
      @project.open().then =>
        expect(@project.watchSupportFile).to.be.calledWith(@config)

    it "calls #getConfig options", ->
      opts = {}
      @project.open(opts).then =>
        expect(@project.getConfig).to.be.calledWith(opts)

    it "updates config.state when saved state changes", ->
      state = savedState(@todosPath)
      getSavedState = @sandbox.stub(state, "get").returns(Promise.resolve({}))
      options = {}
      @project.open(options)
      .then ->
        getSavedState.returns(Promise.resolve({ autoScrollingEnabled: false }))
        options.onSavedStateChanged()
      .then =>
        @project.getConfig()
      .then (config) ->
        expect(config.state).to.eql({ autoScrollingEnabled: false })

    it.skip "watches cypress.json", ->
      @server.open().bind(@).then ->
        expect(Watchers::watch).to.be.calledWith("/Users/brian/app/cypress.json")

    it.skip "passes watchers to Socket.startListening", ->
      options = {}

      @server.open(options).then ->
        startListening = Socket::startListening
        expect(startListening.getCall(0).args[0]).to.be.instanceof(Watchers)
        expect(startListening.getCall(0).args[1]).to.eq(options)

  context "#close", ->
    beforeEach ->
      @project = Project("path/to/project")

      @sandbox.stub(@project, "getConfig").resolves(@config)
      @sandbox.stub(user, "ensureAuthToken").resolves("auth-token-123")

    it "closes server", ->
      @project.server = @sandbox.stub({close: ->})

      @project.close().then =>
        expect(@project.server.close).to.be.calledOnce

    it "closes watchers", ->
      @project.watchers = @sandbox.stub({close: ->})

      @project.close().then =>
        expect(@project.watchers.close).to.be.calledOnce

    it "can close when server + watchers arent open", ->
      @project.close()

  context "#determineIsNewProject", ->
    it "is false when files.length isnt 1", ->
      id = =>
        @ids = Project(@idsPath)
        @ids.getConfig()
        .then (cfg) =>
          @ids.scaffold(cfg).return(cfg)
        .then (cfg) =>
          @ids.determineIsNewProject(cfg.integrationFolder)
        .then (ret) ->
          expect(ret).to.be.false

      todo = =>
        @todos = Project(@todosPath)
        @todos.getConfig()
        .then (cfg) =>
          @todos.scaffold(cfg).return(cfg)
        .then (cfg) =>
          @todos.determineIsNewProject(cfg.integrationFolder)
        .then (ret) ->
          expect(ret).to.be.false

      Promise.join(id, todo)

    it "is true when files, name + bytes match to scaffold", ->
      pristine = Project(@pristinePath)
      pristine.getConfig()
      .then (cfg) ->
        pristine.scaffold(cfg).return(cfg)
      .then (cfg) ->
        pristine.determineIsNewProject(cfg.integrationFolder)
      .then (ret) ->
        expect(ret).to.be.true

    it "is false when bytes dont match scaffold", ->
      pristine = Project(@pristinePath)
      pristine.getConfig()
      .then (cfg) ->
        pristine.scaffold(cfg).return(cfg)
      .then (cfg) ->
        example = scaffold.integrationExampleName()
        file    = path.join(cfg.integrationFolder, example)

        ## write some data to the file so it is now
        ## different in file size
        fs.readFileAsync(file, "utf8")
        .then (str) ->
          str += "foo bar baz"
          fs.writeFileAsync(file, str).return(cfg)
      .then (cfg) ->
        pristine.determineIsNewProject(cfg.integrationFolder)
      .then (ret) ->
        expect(ret).to.be.false

  context "#getBuilds", ->
    beforeEach ->
      @project = Project(@todosPath)
      @sandbox.stub(settings, "read").resolves({projectId: "id-123"})
      @sandbox.stub(api, "getProjectBuilds").resolves('builds')
      @sandbox.stub(user, "ensureAuthToken").resolves("auth-token-123")

    it "calls api.getProjectBuilds with project id + session", ->
      @project.getBuilds().then (builds) ->
        expect(api.getProjectBuilds).to.be.calledWith("id-123", "auth-token-123")
        expect(builds).to.equal("builds")

  context "#scaffold", ->
    beforeEach ->
      @project = Project("path/to/project")
      @sandbox.stub(scaffold, "integration").resolves()
      @sandbox.stub(scaffold, "fixture").resolves()
      @sandbox.stub(scaffold, "support").resolves()

      @obj = {projectRoot: "pr", fixturesFolder: "ff", integrationFolder: "if", supportFolder: "sf"}

    it "calls scaffold.integration with integrationFolder", ->
      @project.scaffold(@obj).then =>
        expect(scaffold.integration).to.be.calledWith(@obj.integrationFolder)

    it "calls fixture.scaffold with fixturesFolder", ->
      @project.scaffold(@obj).then =>
        expect(scaffold.fixture).to.be.calledWith(@obj.fixturesFolder)

    it "calls support.scaffold with supportFolder", ->
      @project.scaffold(@obj).then =>
        expect(scaffold.support).to.be.calledWith(@obj.supportFolder)

  context "#watchSettings", ->
    beforeEach ->
      @project = Project("path/to/project")
      @project.server = {startWebsockets: ->}
      @watch = @sandbox.stub(@project.watchers, "watch")

    it "sets onChange event when {changeEvents: true}", (done) ->
      @project.watchSettingsAndStartWebsockets({onSettingsChanged: done})

      ## get the object passed to watchers.watch
      obj = @watch.getCall(0).args[1]

      expect(obj.onChange).to.be.a("function")
      obj.onChange()

    it "does not call watch when {changeEvents: false}", ->
      @project.watchSettingsAndStartWebsockets({onSettingsChanged: undefined})

      expect(@watch).not.to.be.called

    it "does not call onSettingsChanged when generatedProjectIdTimestamp is less than 1 second", ->
      @project.generatedProjectIdTimestamp = timestamp = new Date

      emit = @sandbox.spy(@project, "emit")

      stub = @sandbox.stub()

      @project.watchSettingsAndStartWebsockets({onSettingsChanged: stub})

      ## get the object passed to watchers.watch
      obj = @watch.getCall(0).args[1]
      obj.onChange()

      expect(stub).not.to.be.called

      ## subtract 1 second from our timestamp
      timestamp.setSeconds(timestamp.getSeconds() - 1)

      obj.onChange()

      expect(stub).to.be.calledOnce

  context "#watchSupportFile", ->
    beforeEach ->
      @project = Project("path/to/project")
      @project.server = {onTestFileChange: @sandbox.spy()}
      @watchBundle = @sandbox.stub(@project.watchers, "watchBundle").returns(Promise.resolve())
      @config = {
        projectRoot: "/path/to/root/"
        supportFile: "/path/to/root/foo/bar.js"
      }

    it "does nothing when {supportFile: false}", ->
      @project.watchSupportFile({supportFile: false})

      expect(@watchBundle).not.to.be.called

    it "calls watchers.watchBundle with relative path to file", ->
      @project.watchSupportFile(@config)

      expect(@watchBundle).to.be.calledWith("foo/bar.js", @config)

    it "calls server.onTestFileChange when file changes", ->
      @project.watchSupportFile(@config)
      @watchBundle.firstCall.args[2].onChange()

      expect(@project.server.onTestFileChange).to.be.calledWith("foo/bar.js")

    it "does not add change listener when {watchForFileChanges: false}", ->
      @config.watchForFileChanges = false
      @project.watchSupportFile(@config)

      expect(@watchBundle.firstCall.args[2]).to.be.undefined

  context "#watchSettingsAndStartWebsockets", ->
    beforeEach ->
      @project = Project("path/to/project")
      @project.watchers = {}
      @project.server = @sandbox.stub({startWebsockets: ->})
      @sandbox.stub(@project, "watchSettings")
      @sandbox.stub(Automation, "create").returns("automation")

    it "calls server.startWebsockets with watchers, automation + config", ->
      c = {}

      @project.watchSettingsAndStartWebsockets({}, c)

      expect(@project.server.startWebsockets).to.be.calledWith(@project.watchers, "automation", c)

    it "passes onReloadBrowser callback", ->
      fn = @sandbox.stub()

      @project.server.startWebsockets.yieldsTo("onReloadBrowser")

      @project.watchSettingsAndStartWebsockets({onReloadBrowser: fn}, {})

      expect(fn).to.be.calledOnce

  context "#getProjectId", ->
    afterEach ->
      delete process.env.CYPRESS_PROJECT_ID

    beforeEach ->
      @project         = Project("path/to/project")
      @verifyExistence = @sandbox.stub(Project.prototype, "verifyExistence").resolves()

    it "resolves with process.env.CYPRESS_PROJECT_ID if set", ->
      process.env.CYPRESS_PROJECT_ID = "123"

      @project.getProjectId().then (id) ->
        expect(id).to.eq("123")

    it "calls verifyExistence", ->
      @sandbox.stub(settings, "read").resolves({projectId: "id-123"})

      @project.getProjectId()
      .then =>
        expect(@verifyExistence).to.be.calledOnce

    it "returns the project id from settings", ->
      @sandbox.stub(settings, "read").resolves({projectId: "id-123"})

      @project.getProjectId()
      .then (id) ->
        expect(id).to.eq "id-123"

    it "throws NO_PROJECT_ID with the projectRoot when no projectId was found", ->
      @sandbox.stub(settings, "read").resolves({})

      @project.getProjectId()
      .then (id) ->
        throw new Error("expected to fail, but did not")
      .catch (err) ->
        expect(err.type).to.eq("NO_PROJECT_ID")
        expect(err.message).to.include("path/to/project")

    it "bubbles up Settings.read errors", ->
      err = new Error
      err.code = "EACCES"

      @sandbox.stub(settings, "read").rejects(err)

      @project.getProjectId()
      .then (id) ->
        throw new Error("expected to fail, but did not")
      .catch (err) ->
        expect(err.code).to.eq("EACCES")

  context "#writeProjectId", ->
    beforeEach ->
      @project = Project("path/to/project")

      @sandbox.stub(settings, "write")
        .withArgs(@project.projectRoot, {projectId: "id-123"})
        .resolves({projectId: "id-123"})

    it "calls Settings.write with projectRoot and attrs", ->
      @project.writeProjectId("id-123").then (id) ->
        expect(id).to.eq("id-123")

    it "sets generatedProjectIdTimestamp", ->
      @project.writeProjectId("id-123").then =>
        expect(@project.generatedProjectIdTimestamp).to.be.a("date")

  context "#ensureSpecUrl", ->
    beforeEach ->
      @project2 = Project(@idsPath)

      settings.write(@idsPath, {port: 2020})

    it "returns fully qualified url when spec exists", ->
      @project2.ensureSpecUrl("cypress/integration/bar.js")
      .then (str) ->
        expect(str).to.eq("http://localhost:2020/__/#/tests/integration/bar.js")

    it "returns fully qualified url on absolute path to spec", ->
      todosSpec = path.join(@todosPath, "tests/sub/sub_test.coffee")
      @project.ensureSpecUrl(todosSpec)
      .then (str) ->
        expect(str).to.eq("http://localhost:8888/__/#/tests/integration/sub/sub_test.coffee")

    it "returns __all spec url", ->
      @project.ensureSpecUrl()
      .then (str) ->
        expect(str).to.eq("http://localhost:8888/__/#/tests/__all")

    it "returns __all spec url with spec is __all", ->
      @project.ensureSpecUrl('__all')
      .then (str) ->
        expect(str).to.eq("http://localhost:8888/__/#/tests/__all")

    it "throws when spec isnt found", ->
      @project.ensureSpecUrl("does/not/exist.js")
      .catch (err) ->
        expect(err.type).to.eq("SPEC_FILE_NOT_FOUND")

  context "#ensureSpecExists", ->
    beforeEach ->
      @project2 = Project(@idsPath)

    it "resolves relative path to test file against projectRoot", ->
      @project2.ensureSpecExists("cypress/integration/foo.coffee")
      .then =>
        @project.ensureSpecExists("tests/test1.js")

    it "resolves + returns absolute path to test file", ->
      idsSpec   = path.join(@idsPath, "cypress/integration/foo.coffee")
      todosSpec = path.join(@todosPath, "tests/sub/sub_test.coffee")

      @project2.ensureSpecExists(idsSpec)
      .then (spec1) =>
        expect(spec1).to.eq(idsSpec)

        @project.ensureSpecExists(todosSpec)
      .then (spec2) ->
        expect(spec2).to.eq(todosSpec)

    it "throws SPEC_FILE_NOT_FOUND when spec does not exist", ->
      @project2.ensureSpecExists("does/not/exist.js")
      .catch (err) =>
        expect(err.type).to.eq("SPEC_FILE_NOT_FOUND")
        expect(err.message).to.include(path.join(@idsPath, "does/not/exist.js"))

  context ".add", ->
    beforeEach ->
      @pristinePath = Fixtures.projectPath("pristine")

    it "inserts path into cache", ->
      Project.add(@pristinePath)
      .then =>
        cache.read()
      .then (json) =>
        expect(json.PROJECTS).to.deep.eq([@pristinePath])

    describe "if project at path has id", ->
      it "returns object containing path and id", ->
        @sandbox.stub(settings, "read").resolves({projectId: "id-123"})

        Project.add(@pristinePath)
        .then (project) =>
          expect(project.id).to.equal("id-123")
          expect(project.path).to.equal(@pristinePath)

    describe "if project at path does not have id", ->
      it "returns object containing just the path", ->
        @sandbox.stub(settings, "read").rejects()

        Project.add(@pristinePath)
        .then (project) =>
          expect(project.id).to.be.undefined
          expect(project.path).to.equal(@pristinePath)

  context "#createCiProject", ->
    beforeEach ->
      @project = Project("path/to/project")
      @newProject = { id: "project-id-123" }

      @sandbox.stub(@project, "writeProjectId").resolves("project-id-123")
      @sandbox.stub(user, "ensureAuthToken").resolves("auth-token-123")
      @sandbox.stub(git, "_getRemoteOrigin").resolves("remoteOrigin")
      @sandbox.stub(api, "createProject")
      .withArgs({foo: "bar"}, "remoteOrigin", "auth-token-123")
      .resolves(@newProject)

    it "calls api.createProject with user session", ->
      @project.createCiProject({foo: "bar"}).then ->
        expect(api.createProject).to.be.calledWith({foo: "bar"}, "remoteOrigin", "auth-token-123")

    it "calls writeProjectId with id", ->
      @project.createCiProject({foo: "bar"}).then =>
        expect(@project.writeProjectId).to.be.calledWith("project-id-123")

    it "returns project id", ->
      @project.createCiProject({foo: "bar"}).then (projectId) =>
        expect(projectId).to.eql(@newProject)

  context "#getRecordKeys", ->
    beforeEach ->
      @recordKeys = []
      @project = Project(@pristinePath)
      @sandbox.stub(settings, "read").resolves({projectId: "id-123"})
      @sandbox.stub(user, "ensureAuthToken").resolves("auth-token-123")
      @sandbox.stub(api, "getProjectRecordKeys").resolves(@recordKeys)

    it "calls api.getProjectRecordKeys with project id + session", ->
      @project.getRecordKeys().then ->
        expect(api.getProjectRecordKeys).to.be.calledWith("id-123", "auth-token-123")

    it "returns ci keys", ->
      @project.getRecordKeys().then (recordKeys) =>
        expect(recordKeys).to.equal(@recordKeys)

  context "#requestAccess", ->
    beforeEach ->
      @project = Project(@pristinePath)
      @sandbox.stub(user, "ensureAuthToken").resolves("auth-token-123")
      @sandbox.stub(api, "requestAccess").resolves("response")

    it "calls api.requestAccess with project id + auth token", ->
      @project.requestAccess("project-id-123").then ->
        expect(api.requestAccess).to.be.calledWith("project-id-123", "auth-token-123")

    it "returns response", ->
      @project.requestAccess("project-id-123").then (response) =>
        expect(response).to.equal("response")

  context ".remove", ->
    beforeEach ->
      @sandbox.stub(cache, "removeProject").resolves()

    it "calls cache.removeProject with path", ->
      Project.remove("path/to/project").then ->
        expect(cache.removeProject).to.be.calledWith("path/to/project")

  context ".exists", ->
    beforeEach ->
      @sandbox.stub(cache, "getProjectPaths").resolves(["foo", "bar", "baz"])

    it "is true if path is in paths", ->
      Project.exists("bar").then (ret) ->
        expect(ret).to.be.true

    it "is false if path isnt in paths", ->
      Project.exists("quux").then (ret) ->
        expect(ret).to.be.false

  context ".id", ->
    it "returns project id", ->
      Project.id(@todosPath).then (id) =>
        expect(id).to.eq(@projectId)

  context ".getOrgs", ->
    beforeEach ->
      @sandbox.stub(user, "ensureAuthToken").resolves("auth-token-123")
      @sandbox.stub(api, "getOrgs").resolves([])

    it "calls api.getOrgs", ->
      Project.getOrgs().then (orgs) ->
        expect(orgs).to.deep.eq([])
        expect(api.getOrgs).to.be.calledOnce
        expect(api.getOrgs).to.be.calledWith("auth-token-123")

  context ".paths", ->
    beforeEach ->
      @sandbox.stub(cache, "getProjectPaths").resolves([])

    it "calls cache.getProjectPaths", ->
      Project.paths().then (ret) ->
        expect(ret).to.deep.eq([])
        expect(cache.getProjectPaths).to.be.calledOnce

  context ".getPathsAndIds", ->
    beforeEach ->
      @sandbox.stub(cache, "getProjectPaths").resolves([
        "/path/to/first"
        "/path/to/second"
      ])
      @sandbox.stub(settings, "id").resolves("id-123")

    it "returns array of objects with paths and ids", ->
      Project.getPathsAndIds().then (pathsAndIds) ->
        expect(pathsAndIds).to.eql([
          {
            path: "/path/to/first"
            id: "id-123"
          }
          {
            path: "/path/to/second"
            id: "id-123"
          }
        ])

  context ".getProjectStatuses", ->
    beforeEach ->
      @sandbox.stub(user, "ensureAuthToken").resolves("auth-token-123")

    it "gets projects from api", ->
      @sandbox.stub(api, "getProjects").resolves([])

      Project.getProjectStatuses([])
      .then ->
        expect(api.getProjects).to.have.been.calledWith("auth-token-123")

    it "returns array of projects", ->
      @sandbox.stub(api, "getProjects").resolves([])

      Project.getProjectStatuses([])
      .then (projectsWithStatuses) =>
        expect(projectsWithStatuses).to.eql([])

    it "returns same number as client projects, even if there are less api projects", ->
      @sandbox.stub(api, "getProjects").resolves([])

      Project.getProjectStatuses([{}])
      .then (projectsWithStatuses) =>
        expect(projectsWithStatuses.length).to.eql(1)

    it "returns same number as client projects, even if there are more api projects", ->
      @sandbox.stub(api, "getProjects").resolves([{}, {}])

      Project.getProjectStatuses([{}])
      .then (projectsWithStatuses) =>
        expect(projectsWithStatuses.length).to.eql(1)

    it "merges in details of matching projects", ->
      @sandbox.stub(api, "getProjects").resolves([
        { id: "id-123", lastBuildStatus: "passing" }
      ])

      Project.getProjectStatuses([{ id: "id-123", path: "/path/to/project" }])
      .then (projectsWithStatuses) =>
        expect(projectsWithStatuses[0]).to.eql({
          id: "id-123"
          path: "/path/to/project"
          lastBuildStatus: "passing"
          state: "VALID"
        })

    it "returns client project when it has no id", ->
      @sandbox.stub(api, "getProjects").resolves([])

      Project.getProjectStatuses([{ path: "/path/to/project" }])
      .then (projectsWithStatuses) =>
        expect(projectsWithStatuses[0]).to.eql({
          path: "/path/to/project"
          state: "VALID"
        })

    describe "when client project has id and there is no matching user project", ->
      beforeEach ->
        @sandbox.stub(api, "getProjects").resolves([])

      it "marks project as invalid if api 404s", ->
        @sandbox.stub(api, "getProject").rejects({name: "", message: "", statusCode: 404})

        Project.getProjectStatuses([{ id: "id-123", path: "/path/to/project" }])
        .then (projectsWithStatuses) =>
          expect(projectsWithStatuses[0]).to.eql({
            id: "id-123"
            path: "/path/to/project"
            state: "INVALID"
          })

      it "marks project as unauthorized if api 403s", ->
        @sandbox.stub(api, "getProject").rejects({name: "", message: "", statusCode: 403})

        Project.getProjectStatuses([{ id: "id-123", path: "/path/to/project" }])
        .then (projectsWithStatuses) =>
          expect(projectsWithStatuses[0]).to.eql({
            id: "id-123"
            path: "/path/to/project"
            state: "UNAUTHORIZED"
          })

      it "merges in project details and marks valid if somehow project exists and is authorized", ->
        @sandbox.stub(api, "getProject").resolves({ id: "id-123", lastBuildStatus: "passing" })

        Project.getProjectStatuses([{ id: "id-123", path: "/path/to/project" }])
        .then (projectsWithStatuses) =>
          expect(projectsWithStatuses[0]).to.eql({
            id: "id-123"
            path: "/path/to/project"
            lastBuildStatus: "passing"
            state: "VALID"
          })

      it "throws error if not accounted for", ->
        error = {name: "", message: ""}
        @sandbox.stub(api, "getProject").rejects(error)

        Project.getProjectStatuses([{ id: "id-123", path: "/path/to/project" }])
        .then =>
          throw new Error("Should throw error")
        .catch (err) ->
          expect(err).to.equal(error)

  context ".getProjectStatus", ->
    beforeEach ->
      @clientProject = {
        id: "id-123",
        path: "/path/to/project"
      }
      @sandbox.stub(user, "ensureAuthToken").resolves("auth-token-123")

    it "gets project from api", ->
      @sandbox.stub(api, "getProject").resolves([])

      Project.getProjectStatus(@clientProject)
      .then ->
        expect(api.getProject).to.have.been.calledWith("id-123", "auth-token-123")

    it "returns project merged with details", ->
      @sandbox.stub(api, "getProject").resolves({
        lastBuildStatus: "passing"
      })

      Project.getProjectStatus(@clientProject)
      .then (project) =>
        expect(project).to.eql({
          id: "id-123"
          path: "/path/to/project"
          lastBuildStatus: "passing"
          state: "VALID"
        })

    it "marks project as invalid if api 404s", ->
      @sandbox.stub(api, "getProject").rejects({name: "", message: "", statusCode: 404})

      Project.getProjectStatus(@clientProject)
      .then (project) =>
        expect(project).to.eql({
          id: "id-123"
          path: "/path/to/project"
          state: "INVALID"
        })

    it "marks project as unauthorized if api 403s", ->
      @sandbox.stub(api, "getProject").rejects({name: "", message: "", statusCode: 403})

      Project.getProjectStatus(@clientProject)
      .then (project) =>
        expect(project).to.eql({
          id: "id-123"
          path: "/path/to/project"
          state: "UNAUTHORIZED"
        })

    it "throws error if not accounted for", ->
      error = {name: "", message: ""}
      @sandbox.stub(api, "getProject").rejects(error)

      Project.getProjectStatus(@clientProject)
      .then =>
        throw new Error("Should throw error")
      .catch (err) ->
        expect(err).to.equal(error)

  context ".removeIds", ->
    beforeEach ->
      @sandbox.stub(ids, "remove").resolves({})

    it "calls id.remove with path to project tests", ->
      p = Fixtures.projectPath("ids")

      Project.removeIds(p).then ->
        expect(ids.remove).to.be.calledWith(p + "/cypress/integration")

  context ".getSecretKeyByPath", ->
    beforeEach ->
      @sandbox.stub(user, "ensureAuthToken").resolves("auth-token-123")

    it "calls api.getProjectToken with id + session", ->
      @sandbox.stub(api, "getProjectToken")
        .withArgs(@projectId, "auth-token-123")
        .resolves("key-123")

      Project.getSecretKeyByPath(@todosPath).then (key) ->
        expect(key).to.eq("key-123")

    it "throws CANNOT_FETCH_PROJECT_TOKEN on error", ->
      @sandbox.stub(api, "getProjectToken")
        .withArgs(@projectId, "auth-token-123")
        .rejects(new Error)

      Project.getSecretKeyByPath(@todosPath)
      .then ->
        throw new Error("should have caught error but did not")
      .catch (err) ->
        expect(err.type).to.eq("CANNOT_FETCH_PROJECT_TOKEN")

  context ".generateSecretKeyByPath", ->
    beforeEach ->
      @sandbox.stub(user, "ensureAuthToken").resolves("auth-token-123")

    it "calls api.updateProjectToken with id + session", ->
      @sandbox.stub(api, "updateProjectToken")
        .withArgs(@projectId, "auth-token-123")
        .resolves("new-key-123")

      Project.generateSecretKeyByPath(@todosPath).then (key) ->
        expect(key).to.eq("new-key-123")

    it "throws CANNOT_CREATE_PROJECT_TOKEN on error", ->
      @sandbox.stub(api, "updateProjectToken")
        .withArgs(@projectId, "auth-token-123")
        .rejects(new Error)

      Project.generateSecretKeyByPath(@todosPath)
      .then ->
        throw new Error("should have caught error but did not")
      .catch (err) ->
        expect(err.type).to.eq("CANNOT_CREATE_PROJECT_TOKEN")
