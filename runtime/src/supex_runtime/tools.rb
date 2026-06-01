# frozen_string_literal: true

require 'fileutils'
require_relative 'utils'
require_relative 'batch_screenshot'
require_relative 'path_policy'

module SupexRuntime
  # Tool implementations for the Supex server
  # Extracted from BridgeServer class to reduce class length
  module Tools
    # Get basic information about the current SketchUp model
    # @return [Hash] model statistics and metadata
    def model_info
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      build_model_info_response(model)
    rescue StandardError => e
      log "Error getting model info: #{e.message}"
      raise "Failed to get model info: #{e.message}"
    end

    # List entities in the model
    # @param params [Hash] parameters with optional entity_type filter
    # @return [Hash] list of entities
    def list_entities(params)
      model = Sketchup.active_model
      entity_type = params['entity_type'] || 'all'
      return { success: false, error: 'No active model' } unless model

      entities = filter_entities_by_type(model, entity_type)
      entities_data = entities.map { |entity| build_entity_data(entity) }

      { success: true, entity_type: entity_type, count: entities_data.length,
        entities: entities_data }
    rescue StandardError => e
      log "Error listing entities: #{e.message}"
      raise "Failed to list entities: #{e.message}"
    end

    # Get currently selected entities
    # @return [Hash] selection information
    def selection_info
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      entities_data = model.selection.map { |entity| build_selection_entity_data(entity) }
      { success: true, count: model.selection.count, entities: entities_data }
    rescue StandardError => e
      log "Error getting selection: #{e.message}"
      raise "Failed to get selection: #{e.message}"
    end

    # Get list of layers (tags) in the model
    # @return [Hash] layers information
    def layers_info
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      layers_data = model.layers.map do |layer|
        { name: layer.name, visible: layer.visible?, page_behavior: layer.page_behavior }
      end
      { success: true, count: layers_data.length, layers: layers_data }
    rescue StandardError => e
      log "Error getting layers: #{e.message}"
      raise "Failed to get layers: #{e.message}"
    end

    # Get list of materials in the model
    # @return [Hash] materials information
    def materials_info
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      materials_data = model.materials.map { |material| build_material_data(material) }
      { success: true, count: materials_data.length, materials: materials_data }
    rescue StandardError => e
      log "Error getting materials: #{e.message}"
      raise "Failed to get materials: #{e.message}"
    end

    # Get current camera information
    # @return [Hash] camera settings
    def camera_info
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      build_camera_info_response(model)
    rescue StandardError => e
      log "Error getting camera info: #{e.message}"
      raise "Failed to get camera info: #{e.message}"
    end

    # Get a bounded hierarchy of model entities for large-project navigation.
    # @param params [Hash] optional root/id/depth/filter parameters
    # @return [Hash] entity tree with summaries and child summaries
    def entity_tree(params)
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      max_depth = int_param(params, 'max_depth', 3)
      include_faces_edges = truthy?(params['include_faces_edges'])
      root = find_entity_from_params(model, params)

      entities = root ? [root] : model.entities.to_a
      nodes = entities.select { |entity| tree_entity?(entity, include_faces_edges) }
                      .map { |entity| build_tree_node(entity, 0, max_depth, include_faces_edges, {}) }

      {
        success: true,
        root: root ? entity_reference(root) : nil,
        max_depth: max_depth,
        include_faces_edges: include_faces_edges,
        count: nodes.length,
        entities: nodes
      }
    rescue StandardError => e
      log "Error building entity tree: #{e.message}"
      raise "Failed to build entity tree: #{e.message}"
    end

    # Find entities by text, type, tag/layer, material, or attribute.
    # @param params [Hash] search parameters
    # @return [Hash] matching entity summaries
    def find_entities(params)
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      max_results = int_param(params, 'max_results', 50)
      max_depth = int_param(params, 'max_depth', 8)
      matches = []

      each_entity_recursive(model.entities, max_depth: max_depth) do |entity, depth|
        next if matches.length >= max_results
        next unless entity_matches_search?(entity, params)

        summary = entity_summary(entity)
        summary[:depth] = depth
        matches << summary
      end

      {
        success: true,
        count: matches.length,
        max_results: max_results,
        entities: matches
      }
    rescue StandardError => e
      log "Error finding entities: #{e.message}"
      raise "Failed to find entities: #{e.message}"
    end

    # Get detailed information for one entity by entity id or persistent id.
    # @param params [Hash] id lookup parameters
    # @return [Hash] entity details
    def entity_details(params)
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      entity = find_entity_from_params(model, params)
      return { success: false, error: 'No entity found for supplied id' } unless entity

      max_depth = int_param(params, 'max_depth', 1)
      include_faces_edges = truthy?(params['include_faces_edges'])

      {
        success: true,
        entity: build_tree_node(entity, 0, max_depth, include_faces_edges, {})
      }
    rescue StandardError => e
      log "Error getting entity details: #{e.message}"
      raise "Failed to get entity details: #{e.message}"
    end

    # List SketchUp scenes/pages with camera summaries.
    # @return [Hash] scene/page list
    def scenes_info
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      pages = model.respond_to?(:pages) ? model.pages : nil
      scenes = pages ? pages.map { |page| page_summary(page, pages) } : []

      { success: true, count: scenes.length, scenes: scenes }
    rescue StandardError => e
      log "Error listing scenes: #{e.message}"
      raise "Failed to list scenes: #{e.message}"
    end

    # Set the active SketchUp camera.
    # @param params [Hash] camera parameters with eye, target, optional up/fov/perspective
    # @return [Hash] new camera info
    def apply_camera(params)
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      eye = point_from_array(params['eye'], 'eye')
      target = point_from_array(params['target'], 'target')
      up = vector_from_array(params['up'] || [0, 0, 1], 'up')
      perspective = params.key?('perspective') ? truthy?(params['perspective']) : true
      fov = params['fov'] || 35.0

      camera = Sketchup::Camera.new(eye, target, up, perspective, fov)
      model.active_view.camera = camera
      model.active_view.zoom_extents if truthy?(params['zoom_extents'])
      model.active_view.invalidate if model.active_view.respond_to?(:invalidate)

      build_camera_info_response(model).merge(success: true)
    rescue StandardError => e
      log "Error setting camera: #{e.message}"
      raise "Failed to set camera: #{e.message}"
    end

    # Run lightweight model hygiene checks for large-project safety.
    # @param params [Hash] optional scope id
    # @return [Hash] validation issues
    def validate_model(params)
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      scope = find_entity_from_params(model, params)
      entities = scope ? child_entities(scope) : model.entities
      issues = []

      validate_loose_root_geometry(model, issues) unless scope
      validate_entities(entities, issues, scope: scope)

      {
        success: true,
        scope: scope ? entity_reference(scope) : nil,
        issue_count: issues.length,
        issues: issues
      }
    rescue StandardError => e
      log "Error validating model: #{e.message}"
      raise "Failed to validate model: #{e.message}"
    end

    # Take a screenshot of the current view and save to disk
    # @param params [Hash] parameters with width, height, transparent, output_path
    # @param workspace [String, nil] workspace path for default output directory
    # @return [Hash] screenshot result with file path (not image data)
    def take_screenshot(params, workspace: nil)
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      # Validate output_path if provided
      if params['output_path']
        PathPolicy.validate!(params['output_path'], operation: 'take_screenshot',
                                                    workspace: workspace)
      end

      screenshot_path = determine_screenshot_path(params['output_path'], workspace)
      write_screenshot(model, screenshot_path, params)
    rescue StandardError => e
      log "Error taking screenshot: #{e.message}"
      log e.backtrace.join("\n")
      raise "Failed to take screenshot: #{e.message}"
    end

    # Take batch screenshots with different camera positions
    # Designed for zero visual flicker - renders happen offscreen
    # @param params [Hash] batch screenshot parameters
    # @param workspace [String, nil] workspace path for default output directory
    # @return [Hash] batch results with file paths
    def batch_screenshot(params, workspace: nil)
      BatchScreenshot.execute(params, workspace: workspace)
    rescue StandardError => e
      log "Error taking batch screenshots: #{e.message}"
      log e.backtrace.join("\n")
      raise "Failed to take batch screenshots: #{e.message}"
    end

    # Open a SketchUp model file
    # @param params [Hash] parameters with file path
    # @param workspace [String, nil] workspace path for path validation
    # @return [Hash] open operation result
    def open_model(params, workspace: nil)
      file_path = params['path']
      return { success: false, error: 'No file path provided' } unless file_path

      PathPolicy.validate!(file_path, operation: 'open_model', workspace: workspace)
      return { success: false, error: "File not found: #{file_path}" } unless File.exist?(file_path)

      requested_path = File.expand_path(file_path)
      schedule_open_model(requested_path)
      model = Sketchup.active_model
      { success: true, scheduled: true, file_path: requested_path, file_name: File.basename(requested_path),
        active_model_path: model&.path.to_s, title: model&.title.to_s }
    rescue StandardError => e
      log "Error opening model: #{e.message}"
      raise "Failed to open model: #{e.message}"
    end

    # Save the current model
    # @param params [Hash] parameters with optional save path
    # @param workspace [String, nil] workspace path for path validation
    # @return [Hash] save operation result
    def save_model(params, workspace: nil)
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      # Validate path if provided
      PathPolicy.validate!(params['path'], operation: 'save_model', workspace: workspace) if params['path']

      saved_path = perform_save(model, params['path'])
      { success: true, file_path: saved_path, file_name: File.basename(saved_path),
        title: model.title }
    rescue StandardError => e
      log "Error saving model: #{e.message}"
      raise "Failed to save model: #{e.message}"
    end

    private

    def schedule_open_model(file_path)
      UI.start_timer(0.1, false) do
        status = Sketchup.open_file(file_path, with_status: true)
        active_path = Sketchup.active_model&.path.to_s
        log "Deferred open_model status=#{status.inspect} active_path=#{active_path.inspect}"
      rescue StandardError => e
        log "Deferred open_model failed: #{e.class}: #{e.message}"
        log e.backtrace.join("\n")
      end
    end

    def int_param(params, key, default)
      value = params[key]
      return default if value.nil?

      value.to_i
    end

    def truthy?(value)
      value == true || value.to_s.downcase == 'true' || value.to_s == '1'
    end

    def build_model_info_response(model)
      units_options = model.options['UnitsOptions']
      length_unit = units_options['LengthUnit']
      units_map = { 0 => 'inches', 1 => 'feet', 2 => 'millimeters', 3 => 'centimeters',
                    4 => 'meters' }

      {
        success: true,
        title: model.title.empty? ? 'Untitled' : model.title,
        units: units_map[length_unit] || 'unknown',
        num_faces: model.entities.grep(Sketchup::Face).count,
        num_edges: model.entities.grep(Sketchup::Edge).count,
        num_groups: model.entities.grep(Sketchup::Group).count,
        num_components: model.entities.grep(Sketchup::ComponentInstance).count,
        modified: model.modified?
      }
    end

    def filter_entities_by_type(model, entity_type)
      case entity_type
      when 'faces' then model.entities.grep(Sketchup::Face)
      when 'edges' then model.entities.grep(Sketchup::Edge)
      when 'groups' then model.entities.grep(Sketchup::Group)
      when 'components' then model.entities.grep(Sketchup::ComponentInstance)
      else model.entities.to_a
      end
    end

    def tree_entity?(entity, include_faces_edges)
      return true if include_faces_edges

      entity.is_a?(Sketchup::Group) ||
        entity.is_a?(Sketchup::ComponentInstance) ||
        entity.typename == 'Image'
    end

    def build_tree_node(entity, depth, max_depth, include_faces_edges, visited)
      node = entity_summary(entity)
      node[:depth] = depth
      node[:child_summary] = entity_collection_summary(child_entities(entity))

      key = entity_visit_key(entity)
      if depth < max_depth && !visited[key]
        visited[key] = true
        children = child_entities(entity).to_a
        child_nodes = children.select { |child| tree_entity?(child, include_faces_edges) }
                              .map do |child|
                                build_tree_node(child, depth + 1, max_depth, include_faces_edges, visited.dup)
                              end
        node[:children] = child_nodes unless child_nodes.empty?
      end

      node
    end

    def entity_summary(entity)
      {
        entity_id: safe_call(entity, :entityID),
        persistent_id: safe_call(entity, :persistent_id),
        type: safe_call(entity, :typename),
        name: entity_name(entity),
        definition_name: definition_name(entity),
        layer: layer_name(entity),
        material: material_name(entity),
        bounds: bounds_hash(entity),
        hidden: boolean_or_nil(entity, :hidden?),
        locked: boolean_or_nil(entity, :locked?),
        valid: entity.respond_to?(:valid?) ? entity.valid? : nil,
        attributes: attributes_hash(entity)
      }
    end

    def entity_reference(entity)
      {
        entity_id: safe_call(entity, :entityID),
        persistent_id: safe_call(entity, :persistent_id),
        type: safe_call(entity, :typename),
        name: entity_name(entity)
      }
    end

    def entity_collection_summary(entities)
      list = entities.respond_to?(:to_a) ? entities.to_a : []
      {
        total: list.length,
        faces: list.count { |entity| entity.is_a?(Sketchup::Face) },
        edges: list.count { |entity| entity.is_a?(Sketchup::Edge) },
        groups: list.count { |entity| entity.is_a?(Sketchup::Group) },
        components: list.count { |entity| entity.is_a?(Sketchup::ComponentInstance) },
        images: list.count { |entity| entity.typename == 'Image' }
      }
    end

    def child_entities(entity)
      case entity
      when Sketchup::Group
        entity.respond_to?(:entities) ? entity.entities : []
      when Sketchup::ComponentInstance
        return [] unless entity.respond_to?(:definition)

        definition = entity.definition
        definition.respond_to?(:entities) ? definition.entities : []
      else
        []
      end
    end

    def each_entity_recursive(entities, max_depth:, depth: 0, visited: {}, &block)
      return if depth > max_depth

      entities.each do |entity|
        block.call(entity, depth)

        key = entity_visit_key(entity)
        next if visited[key]

        visited[key] = true
        children = child_entities(entity)
        next unless children.respond_to?(:each)

        each_entity_recursive(children, max_depth: max_depth, depth: depth + 1,
                                        visited: visited.dup, &block)
      end
    end

    def entity_visit_key(entity)
      safe_call(entity, :persistent_id) || safe_call(entity, :entityID) || entity.object_id
    end

    def find_entity_from_params(model, params)
      id = params['entity_id'] || params['id']
      id_type = params['id_type'] || 'entity_id'

      if params['persistent_id']
        id = params['persistent_id']
        id_type = 'persistent_id'
      end

      return nil if id.nil?

      find_entity(model, id, id_type)
    end

    def find_entity(model, id, id_type)
      target = id.to_s
      found = nil

      each_entity_recursive(model.entities, max_depth: 32) do |entity, _depth|
        current = id_type == 'persistent_id' ? safe_call(entity, :persistent_id) : safe_call(entity, :entityID)
        if current.to_s == target
          found = entity
          break
        end
      end

      found
    end

    def entity_matches_search?(entity, params)
      return false unless matches_entity_type?(entity, params['entity_type'] || params['type'])
      return false unless matches_text?(entity_name(entity), params['name'])
      return false unless matches_text?(layer_name(entity), params['tag'] || params['layer'])
      return false unless matches_text?(material_name(entity), params['material'])
      return false unless matches_attribute?(entity, params)

      query = params['query'].to_s.strip
      return true if query.empty?

      haystack = [
        safe_call(entity, :entityID),
        safe_call(entity, :persistent_id),
        safe_call(entity, :typename),
        entity_name(entity),
        definition_name(entity),
        layer_name(entity),
        material_name(entity)
      ].compact.join(' ').downcase

      haystack.include?(query.downcase)
    end

    def matches_entity_type?(entity, entity_type)
      type = entity_type.to_s.downcase
      return true if type.empty? || type == 'all'
      return container_entity?(entity) if type == 'containers'

      case type
      when 'face', 'faces' then entity.is_a?(Sketchup::Face)
      when 'edge', 'edges' then entity.is_a?(Sketchup::Edge)
      when 'group', 'groups' then entity.is_a?(Sketchup::Group)
      when 'component', 'components' then entity.is_a?(Sketchup::ComponentInstance)
      else entity.typename.to_s.downcase == type
      end
    end

    def matches_text?(value, expected)
      expected.to_s.empty? || value.to_s.downcase.include?(expected.to_s.downcase)
    end

    def matches_attribute?(entity, params)
      dict = params['attribute_dict']
      key = params['attribute_key']
      expected = params['attribute_value']
      return true if dict.to_s.empty? && key.to_s.empty?
      return false unless entity.respond_to?(:get_attribute)

      value = entity.get_attribute(dict, key)
      return !value.nil? if expected.nil?

      value.to_s == expected.to_s
    end

    def entity_name(entity)
      return nil unless entity.respond_to?(:name)

      name = entity.name.to_s
      name.empty? ? nil : name
    end

    def definition_name(entity)
      return nil unless entity.respond_to?(:definition)

      name = entity.definition.name.to_s
      name.empty? ? nil : name
    rescue StandardError
      nil
    end

    def layer_name(entity)
      layer = safe_call(entity, :layer)
      return nil unless layer

      layer.respond_to?(:name) ? layer.name : nil
    end

    def material_name(entity)
      material = safe_call(entity, :material)
      return nil unless material

      material.respond_to?(:display_name) ? material.display_name : material.name
    end

    def attributes_hash(entity)
      return {} unless entity.respond_to?(:attribute_dictionaries)

      dictionaries = entity.attribute_dictionaries
      return {} unless dictionaries

      dictionaries.each_with_object({}) do |dictionary, result|
        result[dictionary.name] = {}
        dictionary.each_pair { |key, value| result[dictionary.name][key.to_s] = value.to_s }
      end
    rescue StandardError
      {}
    end

    def bounds_hash(entity)
      bounds = safe_call(entity, :bounds)
      return nil unless bounds

      hash = Utils.bounds_to_hash(bounds)
      if hash[:min] && hash[:max]
        hash[:dimensions] = [
          hash[:max][0] - hash[:min][0],
          hash[:max][1] - hash[:min][1],
          hash[:max][2] - hash[:min][2]
        ]
      end
      hash
    rescue StandardError
      nil
    end

    def safe_call(object, method_name)
      return nil unless object.respond_to?(method_name)

      object.public_send(method_name)
    rescue StandardError
      nil
    end

    def boolean_or_nil(entity, method_name)
      return nil unless entity.respond_to?(method_name)

      entity.public_send(method_name) ? true : false
    rescue StandardError
      nil
    end

    def point_from_array(value, name)
      raise "#{name} must be [x, y, z]" unless value.is_a?(Array) && value.length == 3

      Geom::Point3d.new(value[0], value[1], value[2])
    end

    def vector_from_array(value, name)
      raise "#{name} must be [x, y, z]" unless value.is_a?(Array) && value.length == 3

      Geom::Vector3d.new(value[0], value[1], value[2])
    end

    def page_summary(page, pages)
      camera = safe_call(page, :camera)
      {
        name: safe_call(page, :name),
        selected: pages.respond_to?(:selected_page) && pages.selected_page == page,
        camera: camera ? camera_summary(camera) : nil
      }
    end

    def camera_summary(camera)
      {
        eye: point_array(camera.eye),
        target: point_array(camera.target),
        up: point_array(camera.up),
        fov: camera.fov,
        perspective: camera.perspective?
      }
    end

    def point_array(point)
      [point.x, point.y, point.z]
    end

    def validate_loose_root_geometry(model, issues)
      model.entities.each do |entity|
        next unless entity.is_a?(Sketchup::Face) || entity.is_a?(Sketchup::Edge)

        issues << {
          severity: 'warning',
          code: 'LOOSE_ROOT_GEOMETRY',
          message: 'Loose face/edge at model root',
          entity: entity_reference(entity)
        }
      end
    end

    def validate_entities(entities, issues, scope: nil)
      each_entity_recursive(entities, max_depth: 32) do |entity, _depth|
        next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)

        if entity_name(entity).nil? && definition_name(entity).nil?
          issues << {
            severity: 'info',
            code: 'UNNAMED_CONTAINER',
            message: 'Group/component has no useful name',
            entity: entity_reference(entity)
          }
        end

        next unless empty_entities?(child_entities(entity))

        issues << {
          severity: 'warning',
          code: 'EMPTY_CONTAINER',
          message: 'Group/component has no child entities',
          entity: entity_reference(entity),
          scope: scope ? entity_reference(scope) : nil
        }
      end
    end

    def empty_entities?(entities)
      return entities.empty? if entities.respond_to?(:empty?)
      return entities.to_a.empty? if entities.respond_to?(:to_a)

      entities.respond_to?(:count) && entities.count < 1
    end

    def container_entity?(entity)
      entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
    end

    def build_entity_data(entity)
      data = { type: entity.typename, entity_id: entity.entityID }

      case entity
      when Sketchup::Group
        data[:name] = entity.name.empty? ? '(unnamed)' : entity.name
        data[:layer] = entity.layer.name
      when Sketchup::ComponentInstance
        data[:name] = entity.definition.name
        data[:layer] = entity.layer.name
      when Sketchup::Face
        data[:area] = entity.area
        data[:layer] = entity.layer.name
      when Sketchup::Edge
        data[:length] = entity.length
        data[:layer] = entity.layer.name
      end

      data
    end

    def build_selection_entity_data(entity)
      data = { type: entity.typename, entity_id: entity.entityID }

      case entity
      when Sketchup::Face
        data[:area] = entity.area
        normal = entity.normal
        data[:normal] = [normal.x, normal.y, normal.z]
      when Sketchup::Edge
        data[:length] = entity.length
      when Sketchup::Group
        data[:name] = entity.name.empty? ? '(unnamed)' : entity.name
      when Sketchup::ComponentInstance
        data[:name] = entity.definition.name
      end

      data
    end

    def build_material_data(material)
      data = { name: material.name, display_name: material.display_name }

      if material.color
        data[:color] = {
          red: material.color.red, green: material.color.green,
          blue: material.color.blue, alpha: material.alpha
        }
      end

      data[:textured] = !material.texture.nil?
      data
    end

    def build_camera_info_response(model)
      camera = model.active_view.camera
      eye = camera.eye
      target = camera.target
      up = camera.up

      {
        success: true,
        eye: [eye.x, eye.y, eye.z],
        target: [target.x, target.y, target.z],
        up: [up.x, up.y, up.z],
        fov: camera.fov,
        aspect_ratio: camera.aspect_ratio,
        perspective: camera.perspective?
      }
    end

    def determine_screenshot_path(output_path, workspace)
      if output_path
        path = File.expand_path(output_path)
        FileUtils.mkdir_p(File.dirname(path))
        path
      else
        screenshots_dir = File.join(PathPolicy.default_tmp_dir(workspace), 'screenshots')
        FileUtils.mkdir_p(screenshots_dir)
        timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
        File.join(screenshots_dir, "screenshot-#{timestamp}.png")
      end
    end

    def write_screenshot(model, screenshot_path, params)
      width = params['width'] || 1920
      height = params['height'] || 1080

      options = {
        filename: screenshot_path, width: width, height: height,
        antialias: true, compression: 0.9, transparent: params['transparent'] || false
      }

      model.active_view.write_image(options)

      {
        success: true, file_path: screenshot_path, file_name: File.basename(screenshot_path),
        width: width, height: height, format: 'png',
        message: "Screenshot saved to #{screenshot_path}. Use Read tool to view if needed."
      }
    end

    def perform_save(model, path)
      if path
        model.save(path)
        path
      else
        model.save
        model.path
      end
    end
  end
end
