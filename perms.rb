class Permissions
  attr_reader :name, :pool, :permissions

  def initialize(server_name, pool_name)
    @name = server_name
    @pool = pool_name
  end

  def load_file(filepath)
    require 'yaml'
    yaml_input = YAML::load_file(filepath)
    @permissions = yaml_input['permissions'].transform_keys(&:to_sym)
    @properties = yaml_input['properties'].transform_keys(&:to_sym)
  end

  def load(dump)
    @permissions = YAML::load(dump).transform_keys(&:to_sym)
  end

  def test_permission(user, requested_perm)
    @permissions[:all].include?(user) || @permissions[requested_perm].include?(user)
  end

  def get_property(requested_prop)
    @properties[requested_prop]
  end

  def save_file!(filepath)
    new_yaml = { 'properties': @properties.transform_keys(&:to_s), 'permissions': @permissions.transform_keys(&:to_s) }.transform_keys(&:to_s)
    File.open(filepath, "w") { |file| file.write(YAML::dump(new_yaml)) }
  end
end
