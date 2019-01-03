require 'minitest/autorun'
require 'yaml'
require_relative '../perms'

class PermissionsTest < Minitest::Test

  def setup
  end

  def teardown
  end

  def test_create_perm
    inst = Permissions.new

    inst2 = Permissions.new(owner:'linux:will')
    assert_equal('linux:will', inst2.owner)
  end

  def test_load_permission_yaml
    inst = Permissions.new
    inst.load_file('config/owner.yml')
    assert_instance_of(Hash, inst.permissions)

    inst.permissions.each do |k,v|
      assert_equal(Symbol, k.class)
    end
  end

  def test_load_hash
    inst = Permissions.new

    input = YAML::load_file('config/owner.yml')
    dump = YAML::dump(input)

    inst.load(dump)
    assert_instance_of(Hash, inst.properties)
    assert_instance_of(Hash, inst.permissions)

    inst.properties.each do |k,v|
      assert_equal(Symbol, k.class)
    end

    inst.permissions.each do |k,v|
      assert_equal(Symbol, k.class)
    end

    assert_equal('linux:will', inst.owner)
    assert_equal('linux:will', inst.properties[:grantors].first)
  end

  def test_check_permission
    inst = Permissions.new
    inst.load_file('config/owner.yml')

    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))

    assert(inst.test_permission('mojang:lessertrustedadmin', :console))

    # test implicit :all
    assert(inst.test_permission('linux:will', :start))
  end

  def test_check_fake_permission
    inst = Permissions.new
    inst.load_file('config/owner.yml')

    assert(!inst.test_permission('mojang:hexparrot', :deleteeverything))
    assert(!inst.test_permission('mojang:fraudster', :dosomethingweird))

    assert(!inst.test_permission('mojang:lessertrustedadmin', :rmrf))

    # test implicit :all
    assert(inst.test_permission('linux:will', :fakebutworks))
  end

  def test_check_permission_from_dump
    inst = Permissions.new
    input = YAML::load_file('config/owner.yml')
    dump = YAML::dump(input)

    inst.load(dump)

    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))

    assert(inst.test_permission('mojang:lessertrustedadmin', :console))

    # test implicit :all
    assert(inst.test_permission('linux:will', :start))
  end

  def test_get_property
    inst = Permissions.new
    inst.load_file('config/owner.yml')

    assert_equal('linux:will', inst.get_property(:owner))
  end

  def test_save_yaml
    inst = Permissions.new
    inst.load_file('config/owner.yml')

    inst.save_file!('config/owner_new.yml')

    inst2 = Permissions.new
    inst2.load_file('config/owner_new.yml')

    assert_equal(inst.permissions, inst2.permissions)
  end

  def test_save_yaml_full_ext
    inst = Permissions.new
    inst.load_file('config/owner.yml')

    inst.save_file!('config/owner_new.yaml')

    inst2 = Permissions.new
    inst2.load_file('config/owner_new.yaml')

    assert_equal(inst.permissions, inst2.permissions)
  end

  def test_save_yaml_as_nonyaml
    inst = Permissions.new
    inst.load_file('config/owner.yml')

    ex = assert_raises(RuntimeError) { inst.save_file!('config/owner_new.txt') }
    assert_equal('cannot save YAML structure as non-yaml file', ex.message)

    ex = assert_raises(RuntimeError) { inst.save_file!('config/owner_new.txt') }
    assert_equal('cannot save YAML structure as non-yaml file', ex.message)

  end

  def test_grant
    inst = Permissions.new
    assert(!inst.test_permission('mojang:hexparrot', :start))

    inst.grant('mojang:hexparrot', :start)
    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))

    inst.grant('mojang:trustedadmin', :start)
    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(inst.test_permission('mojang:trustedadmin', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))
  end

  def test_revoke
    inst = Permissions.new
    assert(!inst.test_permission('mojang:hexparrot', :start))

    inst.grant('mojang:hexparrot', :start)
    assert(inst.test_permission('mojang:hexparrot', :start))

    inst.revoke('mojang:hexparrot', :start)
    assert(!inst.test_permission('mojang:hexparrot', :start))
  end

  def test_grantor?
    inst = Permissions.new
    inst.load_file('config/owner.yml')

    assert(inst.grantor?('linux:will'))
    assert(!inst.grantor?('mojang:hexparrot'))
  end

  def test_make_grantor
    inst = Permissions.new

    assert(!inst.grantor?('linux:will'))
    assert(!inst.grantor?('mojang:hexparrot'))

    inst.make_grantor('linux:will')
    assert(inst.grantor?('linux:will'))

    inst.make_grantor('mojang:hexparrot')
    assert(inst.grantor?('linux:will'))
    assert(inst.grantor?('mojang:hexparrot'))
  end

  def test_unmake_grantor
    inst = Permissions.new

    assert(!inst.grantor?('mojang:hexparrot'))

    inst.make_grantor('mojang:hexparrot')
    assert(inst.grantor?('mojang:hexparrot'))

    inst.unmake_grantor('mojang:hexparrot')
    assert(!inst.grantor?('mojang:hexparrot'))
  end

  def test_owner_is_grantor_load_file
    inst = Permissions.new
    inst.load_file('config/owner.yml')

    assert(inst.grantor?('linux:will'))
    inst.unmake_grantor('linux:will')
    assert(inst.grantor?('linux:will'))
  end

  def test_owner_is_grantor
    inst = Permissions.new(owner:'linux:will')

    assert(inst.grantor?('linux:will'))
  end

  def test_load_file_sets_inst_owner
    inst = Permissions.new
    inst.load_file('config/owner.yml')

    assert_equal('linux:will', inst.owner)
  end

  def test_load_file_doesnt_override_provided_owner
    inst = Permissions.new(owner:'mojang:hexparrot')
    assert_equal('mojang:hexparrot', inst.owner)
    inst.load_file('config/owner.yml')

    assert_equal('mojang:hexparrot', inst.owner)
  end

  def test_save_file_uses_inst_owner
    inst = Permissions.new(owner:'mojang:hexparrot')
    inst.load_file('config/owner.yml')

    inst.save_file!('config/owner_new.yml')

    inst2 = Permissions.new
    inst2.load_file('config/owner_new.yml')

    assert_equal('mojang:hexparrot', inst.owner)
  end
end
