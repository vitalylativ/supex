# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
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

    # Get a compact live-state snapshot for pre-edit grounding.
    # @param params [Hash] optional bounds for reported selection/validation rows
    # @return [Hash] current model, selection, camera, tag, and validation context
    def context_snapshot(params)
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      max_selection = [[int_param(params, 'max_selection', 25), 0].max, 100].min
      max_validation = [[int_param(params, 'max_validation_issues', 10), 0].max, 50].min
      selection = selection_snapshot(model, max_selection)
      validation = lightweight_validation_summary(model, max_validation)
      warnings = []
      warnings.concat(selection.delete(:warnings))
      warnings.concat(validation.delete(:warnings))
      warnings.concat(active_path_warnings(model))

      {
        success: true,
        contract_version: 1,
        model: model_snapshot_summary(model),
        active_path: active_path_summary(model),
        selection: selection,
        camera: camera_summary(model.active_view.camera),
        tags: tag_visibility_summary(model.layers),
        validation: validation,
        warnings: warnings.uniq
      }
    rescue StandardError => e
      log "Error getting context snapshot: #{e.message}"
      raise "Failed to get context snapshot: #{e.message}"
    end

    # Resolve an explicit working scope from the selection or supplied ids.
    # @param params [Hash] source, id, visibility, and depth parameters
    # @return [Hash] bounded scope entities, skipped entities, and fingerprints
    def snapshot_scope(params)
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      source = (params['source'] || 'selection').to_s
      unless %w[selection entity_ids persistent_ids].include?(source)
        return { success: false, error: "Unsupported scope source: #{source}" }
      end

      max_depth = [[int_param(params, 'max_depth', 1), 0].max, 5].min
      max_entities = [[int_param(params, 'max_entities', 50), 1].max, 200].min
      include_faces_edges = truthy?(params['include_faces_edges'])
      visibility = (params['visibility'] || 'visible_only').to_s
      visible_only = visibility != 'all'
      skip_locked = params.key?('skip_locked') ? truthy?(params['skip_locked']) : true

      source_entities, skipped, warnings = resolve_scope_source(model, source, params)
      selection_fingerprint = selection_fingerprint(model)

      if source == 'selection' && source_entities.empty?
        warnings << 'Selection is empty; scope was not expanded to the whole model.'
        return {
          success: true,
          contract_version: 1,
          source: source,
          visibility: visibility,
          include_faces_edges: include_faces_edges,
          max_depth: max_depth,
          count: 0,
          entities: [],
          skipped: skipped,
          warnings: warnings.uniq,
          selection_fingerprint: selection_fingerprint,
          scope_fingerprint: fingerprint_for([])
        }
      end

      entities = []
      visited = {}
      source_entities.each do |entity|
        break if entities.length >= max_entities

        next if duplicate_scope_entity?(entity, visited)

        skip_reasons = scope_skip_reasons(entity, model, visible_only, skip_locked, include_faces_edges)
        unless skip_reasons.empty?
          skipped << skipped_scope_entity(entity, skip_reasons)
          next
        end

        entities << build_scope_node(
          entity, model, 0, max_depth, include_faces_edges,
          visible_only: visible_only, skip_locked: skip_locked, skipped: skipped, visited: {}
        )
      end

      warnings << 'Scope result was truncated by max_entities.' if source_entities.length > max_entities
      warnings.concat(active_path_warnings(model))

      {
        success: true,
        contract_version: 1,
        source: source,
        visibility: visibility,
        include_faces_edges: include_faces_edges,
        skip_locked: skip_locked,
        max_depth: max_depth,
        count: entities.length,
        entities: entities,
        skipped: skipped,
        warnings: warnings.uniq,
        selection_fingerprint: selection_fingerprint,
        scope_fingerprint: fingerprint_for(entities.map { |entity| fingerprint_entity_payload(entity) })
      }
    rescue StandardError => e
      log "Error snapshotting scope: #{e.message}"
      raise "Failed to snapshot scope: #{e.message}"
    end

    # Verify a resolved scope with fresh scope data, validation, and proof views.
    # @param params [Hash] scope and screenshot parameters
    # @param workspace [String, nil] workspace path for screenshot output
    # @return [Hash] verification bundle
    def verify_scope(params, workspace: nil)
      model = Sketchup.active_model
      return { success: false, error: 'No active model' } unless model

      scope = snapshot_scope(params)
      return scope unless scope[:success]

      scope_entity_ids = scope[:entities].map { |entity| entity[:entity_id] }.compact
      validation = verify_scope_validation(scope_entity_ids)
      screenshots = verify_scope_screenshots(params, scope_entity_ids, workspace)
      warnings = []
      warnings.concat(scope[:warnings] || [])
      warnings << 'Scope is empty; screenshots were not captured.' if scope_entity_ids.empty?
      warnings << screenshots[:error] if screenshots.is_a?(Hash) && screenshots[:success] == false

      {
        success: screenshots.nil? || screenshots[:success],
        contract_version: 1,
        scope: scope,
        validation: validation,
        screenshots: screenshots,
        warnings: warnings.compact.uniq
      }
    rescue StandardError => e
      log "Error verifying scope: #{e.message}"
      raise "Failed to verify scope: #{e.message}"
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

    def model_snapshot_summary(model)
      {
        path: model.respond_to?(:path) ? model.path.to_s : nil,
        title: model.title.to_s.empty? ? 'Untitled' : model.title,
        modified: model.respond_to?(:modified?) ? model.modified? : nil,
        units: model_units(model),
        bounds: bounds_hash(model)
      }
    end

    def model_units(model)
      units_options = model.options['UnitsOptions']
      length_unit = units_options['LengthUnit']
      units_map = { 0 => 'inches', 1 => 'feet', 2 => 'millimeters', 3 => 'centimeters',
                    4 => 'meters' }
      units_map[length_unit] || 'unknown'
    rescue StandardError
      'unknown'
    end

    def selection_snapshot(model, max_selection)
      entities = model.selection.to_a
      reported = entities.first(max_selection)
      warnings = []
      warnings << 'Selection summary was truncated.' if entities.length > reported.length

      {
        count: entities.length,
        fingerprint: fingerprint_for(entities.map { |entity| fingerprint_payload(entity) }),
        truncated: entities.length > reported.length,
        entities: reported.map { |entity| selection_summary_entity(entity, model) },
        warnings: warnings
      }
    end

    def selection_fingerprint(model)
      fingerprint_for(model.selection.to_a.map { |entity| fingerprint_payload(entity) })
    end

    def selection_summary_entity(entity, model)
      summary = compact_entity_summary(entity)
      summary[:visibility] = effective_visibility(entity, model)
      summary
    end

    def compact_entity_summary(entity)
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
        valid: entity.respond_to?(:valid?) ? entity.valid? : nil
      }
    end

    def active_path_summary(model)
      entities = active_path_entities(model)
      {
        present: !entities.empty?,
        entities: entities.map { |entity| compact_entity_summary(entity) }
      }
    end

    def active_path_warnings(model)
      return [] if active_path_entities(model).empty?

      ['Active edit path is present; visibility outside the edited context is conservative.']
    end

    def active_path_entities(model)
      path = safe_call(model, :active_path)
      return [] if path.nil?
      return path.to_a.compact if path.respond_to?(:to_a)
      return path.path.compact if path.respond_to?(:path)

      [safe_call(path, :leaf)].compact
    rescue StandardError
      []
    end

    def tag_visibility_summary(layers)
      list = layers.respond_to?(:to_a) ? layers.to_a : layers.map { |layer| layer }
      hidden = []
      visible_count = 0

      list.each do |layer|
        if layer.respond_to?(:visible?) && !layer.visible?
          hidden << {
            name: layer.respond_to?(:name) ? layer.name : nil,
            page_behavior: layer.respond_to?(:page_behavior) ? layer.page_behavior : nil
          }
        else
          visible_count += 1
        end
      end

      {
        visible_count: visible_count,
        hidden_count: hidden.length,
        hidden: hidden.first(25),
        hidden_truncated: hidden.length > 25
      }
    end

    def lightweight_validation_summary(model, max_issues)
      issues = []
      warnings = []

      model.entities.each do |entity|
        break if issues.length >= max_issues
        next unless raw_geometry?(entity)

        issues << {
          severity: 'warning',
          code: 'LOOSE_ROOT_GEOMETRY',
          message: 'Loose face/edge at model root',
          entity: entity_reference(entity)
        }
      end

      model.selection.each do |entity|
        break if issues.length >= max_issues
        next unless container_entity?(entity)
        next unless empty_entities?(child_entities(entity))

        issues << {
          severity: 'warning',
          code: 'EMPTY_SELECTED_CONTAINER',
          message: 'Selected group/component has no child entities',
          entity: entity_reference(entity)
        }
      end

      warnings << 'Validation summary was truncated.' if issues.length >= max_issues

      {
        issue_count: issues.length,
        summary: issues,
        checked: 'root_loose_geometry_and_selected_containers',
        truncated: issues.length >= max_issues,
        warnings: warnings
      }
    end

    def resolve_scope_source(model, source, params)
      skipped = []
      warnings = []

      case source
      when 'selection'
        [model.selection.to_a, skipped, warnings]
      when 'entity_ids'
        [resolve_entities_by_ids(model, Array(params['entity_ids']), 'entity_id', skipped), skipped, warnings]
      when 'persistent_ids'
        [resolve_entities_by_ids(model, Array(params['persistent_ids']), 'persistent_id', skipped), skipped, warnings]
      end
    end

    def resolve_entities_by_ids(model, ids, id_type, skipped)
      ids.map do |id|
        entity = find_entity(model, id, id_type)
        unless entity
          skipped << {
            requested_id: id,
            id_type: id_type,
            reasons: ['not_found']
          }
        end
        entity
      end.compact
    end

    def duplicate_scope_entity?(entity, visited)
      key = entity_visit_key(entity)
      return true if visited[key]

      visited[key] = true
      false
    end

    def scope_skip_reasons(entity, model, visible_only, skip_locked, include_faces_edges)
      reasons = []
      reasons << 'invalid' if entity.respond_to?(:valid?) && !entity.valid?
      reasons << 'raw_geometry_excluded' if !include_faces_edges && raw_geometry?(entity)
      reasons << 'locked' if skip_locked && boolean_or_nil(entity, :locked?)

      if visible_only
        visibility = effective_visibility(entity, model)
        reasons.concat(visibility[:reasons]) unless visibility[:visible]
      end

      reasons.uniq
    end

    def skipped_scope_entity(entity, reasons)
      compact_entity_summary(entity).merge(reasons: reasons)
    end

    def build_scope_node(entity, model, depth, max_depth, include_faces_edges, visible_only:, skip_locked:, skipped:, visited:)
      node = compact_entity_summary(entity)
      node[:depth] = depth
      node[:visibility] = effective_visibility(entity, model)
      node[:child_summary] = entity_collection_summary(child_entities(entity))

      key = entity_visit_key(entity)
      return node if depth >= max_depth || visited[key]

      visited[key] = true
      children = child_entities(entity).to_a
      child_nodes = []
      children.each do |child|
        next unless tree_entity?(child, include_faces_edges)

        reasons = scope_skip_reasons(child, model, visible_only, skip_locked, include_faces_edges)
        unless reasons.empty?
          skipped << skipped_scope_entity(child, reasons)
          next
        end

        child_nodes << build_scope_node(
          child, model, depth + 1, max_depth, include_faces_edges,
          visible_only: visible_only, skip_locked: skip_locked, skipped: skipped, visited: visited.dup
        )
      end
      node[:children] = child_nodes unless child_nodes.empty?
      node
    end

    def verify_scope_validation(scope_entity_ids)
      results = scope_entity_ids.map do |entity_id|
        validation = validate_model({ 'id' => entity_id, 'id_type' => 'entity_id' })
        {
          entity_id: entity_id,
          issue_count: validation[:issue_count],
          issues: validation[:issues]
        }
      end

      {
        scope_count: scope_entity_ids.length,
        issue_count: results.sum { |result| result[:issue_count].to_i },
        results: results
      }
    end

    def verify_scope_screenshots(params, scope_entity_ids, workspace)
      include_screenshots = params.key?('include_screenshots') ? truthy?(params['include_screenshots']) : true
      return nil unless include_screenshots
      return nil if scope_entity_ids.empty?

      screenshot_params = {
        'shots' => [],
        'scope_entity_ids' => scope_entity_ids,
        'standard_scope_views' => params.key?('standard_scope_views') ? params['standard_scope_views'] : true,
        'base_name' => params['base_name'] || 'scope_verify',
        'restore_camera' => params.key?('restore_camera') ? truthy?(params['restore_camera']) : true
      }
      %w[output_dir width height transparent].each do |key|
        screenshot_params[key] = params[key] if params.key?(key)
      end

      batch_screenshot(screenshot_params, workspace: workspace)
    end

    def effective_visibility(entity, model)
      reasons = []
      warnings = []

      reasons << 'entity_hidden' if boolean_or_nil(entity, :hidden?)
      reasons << 'tag_hidden' if tag_hidden?(entity)

      visibility_ancestors(entity, model).each do |ancestor|
        reasons << 'ancestor_hidden' if boolean_or_nil(ancestor, :hidden?)
        reasons << 'ancestor_tag_hidden' if tag_hidden?(ancestor)
      end

      if hidden_by_active_edit_context?(entity, model)
        reasons << 'outside_active_edit_path'
      elsif !active_path_entities(model).empty?
        warnings << 'Active edit path relation was only partially checked.'
      end

      {
        visible: reasons.empty?,
        reasons: reasons.uniq,
        warnings: warnings.uniq
      }
    end

    def tag_hidden?(entity)
      layer = safe_call(entity, :layer)
      layer.respond_to?(:visible?) && !layer.visible?
    rescue StandardError
      false
    end

    def visibility_ancestors(entity, model)
      ancestors = []
      seen = {}
      current = entity

      loop do
        ancestor = parent_visibility_entity(current)
        break unless ancestor

        key = entity_visit_key(ancestor)
        break if seen[key]

        ancestors << ancestor
        seen[key] = true
        current = ancestor
      end

      active_path_entities(model).each do |ancestor|
        next if same_entity?(ancestor, entity)
        next if ancestors.any? { |existing| same_entity?(existing, ancestor) }

        ancestors << ancestor
      end

      ancestors
    end

    def parent_visibility_entity(entity)
      parent = safe_call(entity, :parent)
      return parent if parent && container_entity?(parent)

      if defined?(Sketchup::ComponentDefinition) && parent.is_a?(Sketchup::ComponentDefinition)
        instances = parent.respond_to?(:instances) ? parent.instances : []
        return instances.first if instances.respond_to?(:length) && instances.length == 1
      end

      nil
    rescue StandardError
      nil
    end

    def hidden_by_active_edit_context?(entity, model)
      active_path = active_path_entities(model)
      return false if active_path.empty?
      return false unless model.respond_to?(:rendering_options)
      return false unless model.rendering_options['InactiveHidden']
      return false if active_path.any? { |path_entity| same_entity?(path_entity, entity) }
      return false unless root_level_entity?(entity, model)

      true
    rescue StandardError
      false
    end

    def root_level_entity?(entity, model)
      model.entities.to_a.any? { |root_entity| same_entity?(root_entity, entity) }
    rescue StandardError
      false
    end

    def same_entity?(left, right)
      return true if left.equal?(right)

      left_id = safe_call(left, :entityID)
      right_id = safe_call(right, :entityID)
      !left_id.nil? && left_id == right_id
    end

    def raw_geometry?(entity)
      entity.is_a?(Sketchup::Face) || entity.is_a?(Sketchup::Edge)
    end

    def fingerprint_for(payload)
      Digest::SHA256.hexdigest(JSON.generate(payload))[0, 16]
    end

    def fingerprint_payload(entity)
      {
        entity_id: safe_call(entity, :entityID),
        persistent_id: safe_call(entity, :persistent_id),
        type: safe_call(entity, :typename),
        name: entity_name(entity),
        definition_name: definition_name(entity),
        layer: layer_name(entity),
        bounds: bounds_hash(entity)
      }
    end

    def fingerprint_entity_payload(scope_entity)
      {
        entity_id: scope_entity[:entity_id],
        persistent_id: scope_entity[:persistent_id],
        type: scope_entity[:type],
        name: scope_entity[:name],
        definition_name: scope_entity[:definition_name],
        layer: scope_entity[:layer],
        bounds: scope_entity[:bounds]
      }
    end

    def build_model_info_response(model)
      {
        success: true,
        title: model.title.empty? ? 'Untitled' : model.title,
        units: model_units(model),
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
