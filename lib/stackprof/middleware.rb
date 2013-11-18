module StackProf
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      StackProf.start(mode: :cpu, interval: 1000) if self.class.enabled?
      @app.call(env)
    ensure
      StackProf.stop if self.class.enabled?
    end

    class << self
      attr_accessor :enabled
      alias enabled? enabled
    end
  end
end
