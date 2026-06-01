# frozen_string_literal: true

require_relative 'helpers/test_helper'
require_relative '../src/supex_runtime/bridge_server'

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
