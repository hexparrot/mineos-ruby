require 'test_helper'

class ServerTest < ActiveSupport::TestCase
  test "name setter" do
    inst = Server.new(name: 'test')
    assert(inst.name, 'test')
  end

  test "live directory" do
    inst = Server.new(name: 'test')
    assert_equal('/var/games/minecraft/servers/test', inst.cwd)
  end

  test "backup directory" do
    inst = Server.new(name: 'test')
    assert_equal('/var/games/minecraft/backup/test', inst.bwd)
  end

  test "archive directory" do
    inst = Server.new(name: 'test')
    assert_equal('/var/games/minecraft/archive/test', inst.awd)
  end

  test "second live directory" do
    inst = Server.new(name: 'test2')
    assert_equal('/var/games/minecraft/servers/test2', inst.cwd)
  end

  test "second backup directory" do
    inst = Server.new(name: 'test2')
    assert_equal('/var/games/minecraft/backup/test2', inst.bwd)
  end

  test "second archive directory" do
    inst = Server.new(name: 'test2')
    assert_equal('/var/games/minecraft/archive/test2', inst.awd)
  end

end
