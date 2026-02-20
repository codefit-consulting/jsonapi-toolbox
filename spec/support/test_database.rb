# frozen_string_literal: true

require "active_record"
require "fileutils"

module TestDatabase
  DB_DIR = File.expand_path("../../tmp", __dir__)
  DB_PATH = File.join(DB_DIR, "test.sqlite3")

  def self.setup!(pool: 5)
    FileUtils.mkdir_p(DB_DIR)
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: DB_PATH, pool: pool)
  end

  def self.teardown!
    ActiveRecord::Base.connection_pool.disconnect!
    FileUtils.rm_f(DB_PATH)
  end
end
