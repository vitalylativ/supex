# frozen_string_literal: true

require_relative 'helpers/test_helper'
require_relative '../src/supex_runtime/bridge_server'
require 'tmpdir'

class TestModelNavigationTools < Minitest::Test
  def setup
    UI.clear_timers
    UI.reset_ui_mocks
    SupexRuntime::Utils.clear_console_output
    Sketchup.reset_mocks
    @server = SupexRuntime::BridgeServer.new(port: 0)
    @model = MockModel.new(title: 'Navigation Test')
    Sketchup.mock_model = @model
  end

  def teardown
    @server&.stop
    UI.clear_timers
    SupexRuntime::Utils.clear_console_output
  end

  def test_get_entity_tree_returns_container_hierarchy
    facade = Sketchup::Group.new(id: 10, name: 'Front Facade')
    balcony = Sketchup::Group.new(id: 11, name: 'Balcony A')
    loose_face = Sketchup::Face.new(id: 12)
    facade.entities.add_entity(balcony)
    @model.entities.add_entity(facade)
    @model.entities.add_entity(loose_face)

    result = @server.send(:execute_tool, 'get_entity_tree', { 'max_depth' => 2 }, nil)

    assert result[:success]
    assert_equal 1, result[:count]
    assert_equal 'Front Facade', result[:entities].first[:name]
    assert_equal 'Balcony A', result[:entities].first[:children].first[:name]
  end

  def test_find_entities_searches_nested_containers
    facade = Sketchup::Group.new(id: 20, name: 'Front Facade')
    balcony = Sketchup::Group.new(id: 21, name: 'Balcony East')
    facade.entities.add_entity(balcony)
    @model.entities.add_entity(facade)

    result = @server.send(:execute_tool, 'find_entities', { 'query' => 'balcony' }, nil)

    assert result[:success]
    assert_equal 1, result[:count]
    assert_equal 21, result[:entities].first[:entity_id]
  end

  def test_get_entity_details_by_entity_id
    group = Sketchup::Group.new(id: 30, name: 'Kitchen Island')
    group.set_attribute('supex', 'role', 'furniture')
    @model.entities.add_entity(group)

    result = @server.send(:execute_tool, 'get_entity_details', { 'id' => 30 }, nil)

    assert result[:success]
    assert_equal 'Kitchen Island', result[:entity][:name]
    assert_equal 'furniture', result[:entity][:attributes]['supex']['role']
  end

  def test_list_scenes_returns_pages
    page = MockPage.new(name: 'Iso View')
    @model.pages.add(page)

    result = @server.send(:execute_tool, 'list_scenes', {}, nil)

    assert result[:success]
    assert_equal 1, result[:count]
    assert_equal 'Iso View', result[:scenes].first[:name]
    assert result[:scenes].first[:selected]
  end

  def test_set_camera_updates_active_view_camera
    result = @server.send(:execute_tool, 'set_camera', {
                            'eye' => [10, 20, 30],
                            'target' => [0, 0, 0],
                            'up' => [0, 0, 1],
                            'fov' => 50.0,
                            'perspective' => true
                          }, nil)

    assert result[:success]
    assert_equal [10.0, 20.0, 30.0], result[:eye]
    assert_equal 50.0, @model.active_view.camera.fov
  end

  def test_get_context_snapshot_returns_bounded_grounding_state
    @model.path = '/tmp/navigation-test.skp'
    @model.options['UnitsOptions']['LengthUnit'] = 4
    hidden_layer = MockLayer.new(name: 'Hidden Context', visible: false)
    @model.layers.add_layer(hidden_layer)
    group = Sketchup::Group.new(id: 50, name: 'Selected Tower')
    @model.entities.add_entity(group)
    @model.selection.add(group)

    result = @server.send(:execute_tool, 'get_context_snapshot', {}, nil)

    assert result[:success]
    assert_equal 1, result[:contract_version]
    assert_equal '/tmp/navigation-test.skp', result[:model][:path]
    assert_equal 'meters', result[:model][:units]
    assert_equal 1, result[:selection][:count]
    assert_equal 'Selected Tower', result[:selection][:entities].first[:name]
    assert result[:selection][:fingerprint].is_a?(String)
    assert_equal 1, result[:tags][:hidden_count]
    assert_equal 'Hidden Context', result[:tags][:hidden].first[:name]
    assert_equal 'root_loose_geometry_and_selected_containers', result[:validation][:checked]
    assert result[:camera][:eye]
  end

  def test_snapshot_scope_empty_selection_does_not_expand_to_whole_model
    @model.entities.add_entity(Sketchup::Group.new(id: 51, name: 'Unselected Tower'))

    result = @server.send(:execute_tool, 'snapshot_scope', {}, nil)

    assert result[:success]
    assert_equal 'selection', result[:source]
    assert_equal 0, result[:count]
    assert_empty result[:entities]
    assert_includes result[:warnings], 'Selection is empty; scope was not expanded to the whole model.'
  end

  def test_snapshot_scope_defaults_to_visible_unlocked_containers
    visible = Sketchup::Group.new(id: 52, name: 'Visible Scope')
    hidden = Sketchup::Group.new(id: 53, name: 'Hidden Scope')
    hidden.hidden = true
    locked = Sketchup::Group.new(id: 54, name: 'Locked Scope')
    locked.locked = true
    face = Sketchup::Face.new(id: 55)
    [visible, hidden, locked, face].each do |entity|
      @model.entities.add_entity(entity)
      @model.selection.add(entity)
    end

    result = @server.send(:execute_tool, 'snapshot_scope', {}, nil)

    assert result[:success]
    assert_equal 1, result[:count]
    assert_equal 52, result[:entities].first[:entity_id]
    skipped = result[:skipped].each_with_object({}) { |entity, index| index[entity[:entity_id]] = entity[:reasons] }
    assert_includes skipped[53], 'entity_hidden'
    assert_includes skipped[54], 'locked'
    assert_includes skipped[55], 'raw_geometry_excluded'
    assert result[:selection_fingerprint].is_a?(String)
    assert result[:scope_fingerprint].is_a?(String)
  end

  def test_snapshot_scope_resolves_entity_and_persistent_ids_without_selection
    group = Sketchup::Group.new(id: 56, name: 'Explicit Scope')
    @model.entities.add_entity(group)

    by_entity = @server.send(:execute_tool, 'snapshot_scope', {
                               'source' => 'entity_ids',
                               'entity_ids' => [56, 999_999]
                             }, nil)
    by_persistent = @server.send(:execute_tool, 'snapshot_scope', {
                                   'source' => 'persistent_ids',
                                   'persistent_ids' => [group.persistent_id]
                                 }, nil)

    assert by_entity[:success]
    assert_equal 1, by_entity[:count]
    assert_equal 56, by_entity[:entities].first[:entity_id]
    assert_equal ['not_found'], by_entity[:skipped].first[:reasons]
    assert by_persistent[:success]
    assert_equal 56, by_persistent[:entities].first[:entity_id]
  end

  def test_snapshot_scope_excludes_entities_with_hidden_ancestors
    parent = Sketchup::Group.new(id: 57, name: 'Hidden Parent')
    parent.hidden = true
    child = Sketchup::Group.new(id: 58, name: 'Nested Child', parent: parent)
    parent.entities.add_entity(child)
    @model.entities.add_entity(parent)

    result = @server.send(:execute_tool, 'snapshot_scope', {
                            'source' => 'entity_ids',
                            'entity_ids' => [58]
                          }, nil)

    assert result[:success]
    assert_equal 0, result[:count]
    assert_equal 58, result[:skipped].first[:entity_id]
    assert_includes result[:skipped].first[:reasons], 'ancestor_hidden'
  end

  def test_verify_scope_reports_empty_scope_without_screenshots
    result = @server.send(:execute_tool, 'verify_scope', {}, nil)

    assert result[:success]
    assert_equal 0, result[:scope][:count]
    assert_nil result[:screenshots]
    assert_includes result[:warnings], 'Selection is empty; scope was not expanded to the whole model.'
    assert_includes result[:warnings], 'Scope is empty; screenshots were not captured.'
  end

  def test_verify_scope_composes_snapshot_validation_and_scoped_screenshots
    workspace = Dir.mktmpdir('supex_verify_scope')
    output_dir = File.join(workspace, '.tmp', 'verify_scope')
    group = Sketchup::Group.new(id: 59, name: 'Verified Scope')
    group.entities.add_entity(Sketchup::Group.new(id: 60, name: 'Empty Child'))
    @model.entities.add_entity(group)
    @model.selection.add(group)

    result = @server.send(:execute_tool, 'verify_scope', {
                            'output_dir' => output_dir,
                            'base_name' => 'verify'
                          }, workspace)

    assert result[:success]
    assert_equal 1, result[:scope][:count]
    assert_equal 1, result[:validation][:scope_count]
    assert result[:validation][:issue_count] >= 1
    assert_equal true, result[:screenshots][:success]
    assert_equal %w[scope_top scope_front scope_iso], result[:screenshots][:results].map { |shot| shot[:name] }
  ensure
    FileUtils.rm_rf(workspace) if workspace
  end

  def test_validate_model_reports_loose_root_geometry_and_empty_groups
    @model.entities.add_entity(Sketchup::Face.new(id: 40))
    @model.entities.add_entity(Sketchup::Group.new(id: 41, name: 'Empty Group'))

    result = @server.send(:execute_tool, 'validate_model', {}, nil)

    assert result[:success]
    codes = result[:issues].map { |issue| issue[:code] }
    assert_includes codes, 'LOOSE_ROOT_GEOMETRY'
    assert_includes codes, 'EMPTY_CONTAINER'
  end
end
