class Permissions
  attr_accessor :permissions, :properties, :hostname, :workerpool, :servername

  def initialize(owner)
    @properties = {}
    @permissions = {}

    @properties[:owner] = owner
    make_grantor(owner)
  end

  def load_file(filepath)
    require 'yaml'
    yaml_input = YAML::load_file(filepath)

    owner = @properties[:owner]
    @permissions = yaml_input['permissions'].transform_keys(&:to_sym)
    @properties = yaml_input['properties'].transform_keys(&:to_sym)
    @properties[:owner] = owner if owner
  end

  def load(dump)
    owner = @properties[:owner]
    @properties = YAML::load(dump)['properties'].transform_keys(&:to_sym)
    @permissions = YAML::load(dump)['permissions'].transform_keys(&:to_sym)
    @properties[:owner] = owner if owner
  end

  def dump
    new_yaml = { 'properties': @properties.transform_keys(&:to_s), 'permissions': @permissions.transform_keys(&:to_s) }.transform_keys(&:to_s)
    YAML::dump(new_yaml)
  end

  def test_permission(user, requested_perm)
    return true if @permissions.key?(:all) && @permissions[:all].include?(user)
    return true if @permissions.key?(requested_perm) && @permissions[requested_perm].include?(user)
    false
  end

  def owner
    @properties[:owner]
  end

  def grantors
    @properties[:grantors]
  end

  def save_file!(filepath)
    raise RuntimeError.new("cannot save YAML structure as non-yaml file") if !['.yml', '.yaml'].include?(File.extname(filepath))

    new_yaml = { 'properties': @properties.transform_keys(&:to_s), 'permissions': @permissions.transform_keys(&:to_s) }.transform_keys(&:to_s)
    File.open(filepath, "w") { |file| file.write(YAML::dump(new_yaml)) }
  end

  def grant(user, permission)
    if !@permissions.key?(permission) then
      @permissions[permission] = [user]
    else
      @permissions[permission] << user
    end
  end

  def revoke(user, permission)
    @permissions[permission].delete(user) if @permissions.key?(permission) && @permissions[permission].include?(user)
  end

  def grantor?(user)
    if @properties[:owner] == user then
      true
    elsif @properties.key?(:grantors) then
      @properties[:grantors].include?(user)
    else
      false
    end
  end

  def make_grantor(user)
    if !@properties.key?(:grantors) then
      @properties[:grantors] = [user]
    else
      @properties[:grantors] << user
    end
  end

  def unmake_grantor(user)
    @properties[:grantors].delete(user) if @properties[:grantors].include?(user)
  end
end
