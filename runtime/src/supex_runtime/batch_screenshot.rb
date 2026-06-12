# frozen_string_literal: true

require 'fileutils'
require_relative 'path_policy'

module SupexRuntime
  # Batch screenshot functionality with zero-flicker camera control
  #
  # This module enables taking multiple screenshots with different camera positions
  # in a single batch operation, designed to minimize or eliminate visual flicker
  # for the SketchUp user.
  #
  # Zero-flicker strategy:
  # 1. Use start_operation with disable_ui=true to suppress UI updates
  # 2. write_image renders offscreen when dimensions differ from viewport
  # 3. Process all shots rapidly in sequence
  # 4. Restore original camera immediately after batch completes
  #
  # Isolation feature:
  # Each shot can specify 'isolate' => entity_id to show only that subtree.
  # This uses SketchUp's "Hide rest of Model" and "Hide similar components":
  # 1. Opening the entity for editing (model.active_path)
  # 2. Enabling InactiveHidden (hides rest of model)
  # 3. Enabling InstanceHidden (hides other instances of same component)
  # 4. zoom_extents then works only on the isolated instance
  module BatchScreenshot
    # Standard view camera configurations
    # Direction points FROM camera TO model center, Up defines camera orientation
    STANDARD_VIEWS = {
      'top' => { direction: [0, 0, -1], up: [0, 1, 0] },
      'bottom' => { direction: [0, 0, 1], up: [0, -1, 0] },
      'front' => { direction: [0, 1, 0], up: [0, 0, 1] },
      'back' => { direction: [0, -1, 0], up: [0, 0, 1] },
      'left' => { direction: [1, 0, 0], up: [0, 0, 1] },
      'right' => { direction: [-1, 0, 0], up: [0, 0, 1] },
      'iso' => { direction: [-1, -1, -1], up: [0, 0, 1] }
    }.freeze

    class << self
      # Execute batch screenshot operation
      # @param params [Hash] batch parameters
      # @param workspace [String, nil] workspace path for default output directory
      # @return [Hash] results with file paths and any errors
      def execute(params, workspace: nil)
        # Fallback to env when called directly (e.g., from test snippets)
        # rather than via tool dispatch which passes workspace explicitly
        workspace ||= ENV['SUPEX_WORKSPACE']

        model = Sketchup.active_model
        return { success: false, error: 'No active model' } unless model

        scope_entity_ids = normalize_scope_entity_ids(params['scope_entity_ids'])
        shots = expand_scope_shots(params['shots'] || [], scope_entity_ids, params['standard_scope_views'])
        return { success: false, error: 'No shots specified' } if shots.empty?

        view = model.active_view
        output_dir = prepare_output_dir(params['output_dir'], workspace)
        base_name = params['base_name'] || 'screenshot'
        defaults = extract_defaults(params)

        # Save original camera state for restoration
        original_camera = save_camera_state(view.camera)

        # Process all shots with UI suppression for zero-flicker
        results = process_shots_with_ui_suppression(
          model, view, shots, output_dir, base_name, defaults
        )

        # Restore original camera if requested (default: true)
        restore_camera_state(view, original_camera) if params['restore_camera'] != false

        build_response(results, output_dir, scope_entity_ids)
      rescue PathPolicy::PathAccessDenied => e
        { success: false, error: e.message, error_code: 'PATH_NOT_ALLOWED' }
      rescue StandardError => e
        { success: false, error: e.message, backtrace: e.backtrace.first(5) }
      end

      private

      def normalize_scope_entity_ids(ids)
        Array(ids).map { |id| id.to_i }.reject(&:zero?).uniq
      end

      def expand_scope_shots(shots, scope_entity_ids, standard_scope_views)
        expanded = shots.dup
        return expanded if scope_entity_ids.empty? || !standard_scope_views

        scope_views = normalize_scope_views(standard_scope_views)
        scope_views.each do |view_name|
          expanded << {
            'name' => "scope_#{view_name}",
            'camera' => {
              'type' => 'scope_standard_view',
              'view' => view_name,
              'entity_ids' => scope_entity_ids,
              'padding' => 1.05
            }
          }
        end
        expanded
      end

      def normalize_scope_views(standard_scope_views)
        requested = standard_scope_views == true ? %w[top front iso] : Array(standard_scope_views)
        requested.map(&:to_s).map { |view| view.sub(/\Ascope_/, '') }
                 .select { |view| %w[top front iso].include?(view) }
                 .uniq
      end

      # Process all shots within a single operation for UI suppression
      # @param model [Sketchup::Model] the model
      # @param view [Sketchup::View] the view
      # @param shots [Array<Hash>] shot specifications
      # @param output_dir [String] output directory path
      # @param base_name [String] base filename
      # @param defaults [Hash] default parameters
      # @return [Array<Hash>] results for each shot
      def process_shots_with_ui_suppression(model, view, shots, output_dir, base_name, defaults)
        results = []

        # Use start_operation with disable_ui=true to suppress UI updates
        # This minimizes flicker during rapid camera changes
        model.start_operation('Batch Screenshot', true)

        begin
          shots.each_with_index do |shot, index|
            result = process_single_shot(view, model, shot, output_dir, base_name, index, defaults)
            results << result
          end
          model.commit_operation
        rescue StandardError => e
          model.abort_operation
          raise e
        end

        results
      end

      # Process a single shot
      # @param view [Sketchup::View] the view
      # @param model [Sketchup::Model] the model
      # @param shot [Hash] shot specification
      # @param output_dir [String] output directory
      # @param base_name [String] base filename
      # @param index [Integer] shot index
      # @param defaults [Hash] default parameters
      # @return [Hash] result for this shot
      def process_single_shot(view, model, shot, output_dir, base_name, index, defaults)
        camera_spec = shot['camera'] || {}
        shot_name = shot['name'] || format('%03d', index)
        isolate_id = shot['isolate']

        width = shot['width'] || defaults[:width]
        height = shot['height'] || defaults[:height]

        isolation_state = nil

        begin
          # Apply isolation if requested (opens entity and hides rest of model)
          if isolate_id
            isolation_state = save_isolation_state(model)
            apply_isolation(model, isolate_id)
          end

          # Apply camera for this shot
          camera_warnings = apply_camera(view, model, camera_spec)

          # Generate filename and verify it stays within output_dir
          filename = "#{base_name}_#{shot_name}.png"
          filepath = File.join(output_dir, filename)
          canonical = File.expand_path(filepath)
          unless canonical.start_with?(output_dir + File::SEPARATOR) || canonical == output_dir
            raise PathPolicy::PathAccessDenied,
                  "Path access denied for batch_screenshot: shot path escapes output directory"
          end

          # Take screenshot (offscreen render due to explicit dimensions)
          write_screenshot(view, filepath, width, height, defaults[:transparent])

          result = {
            success: true,
            file_path: filepath,
            name: shot_name,
            camera: save_camera_state(view.camera)
          }
          result[:scope_entity_ids] = camera_spec['entity_ids'] if camera_spec['entity_ids']
          result[:warnings] = camera_warnings unless camera_warnings.empty?
          result
        rescue StandardError => e
          { success: false, name: shot_name, error: e.message }
        ensure
          # Always restore isolation state if it was modified
          restore_isolation_state(model, isolation_state) if isolation_state
        end
      end

      # Apply camera based on specification
      # @param view [Sketchup::View] the view
      # @param model [Sketchup::Model] the model
      # @param camera_spec [Hash] camera specification
      # @note zoom_extents flag (default: true) adjusts camera to fit all visible content
      def apply_camera(view, model, camera_spec)
        type = camera_spec['type'] || 'standard_view'
        zoom = camera_spec['zoom_extents'] != false # Default true
        warnings = []

        case type
        when 'standard_view'
          apply_standard_view(view, model, camera_spec['view'])
        when 'custom'
          apply_custom_camera(view, camera_spec)
        when 'zoom_entity'
          warnings.concat(apply_zoom_entity(view, model, camera_spec))
          return warnings # zoom_entity has its own zoom logic
        when 'scope_standard_view'
          warnings.concat(apply_scope_standard_view(view, model, camera_spec))
          return warnings
        else
          raise "Unknown camera type: #{type}"
        end

        # Apply zoom_extents after setting camera direction
        view.zoom_extents if zoom
        warnings
      end

      # Apply a standard view (top, front, iso, etc.)
      # Sets camera direction only - zoom_extents flag handles optimal distance
      # @param view [Sketchup::View] the view
      # @param model [Sketchup::Model] the model
      # @param view_name [String] name of the standard view
      def apply_standard_view(view, model, view_name, bounds = nil)
        config = STANDARD_VIEWS[view_name.to_s.downcase]
        raise "Unknown standard view: #{view_name}" unless config

        bounds ||= model.bounds
        center = bounds.empty? ? ORIGIN : bounds.center

        direction = Geom::Vector3d.new(*config[:direction]).normalize
        up = Geom::Vector3d.new(*config[:up])

        # Set arbitrary distance - zoom_extents will adjust if enabled
        eye = center.offset(direction.reverse, 100)

        camera = Sketchup::Camera.new(eye, center, up)
        camera.perspective = false # Standard views use parallel projection
        view.camera = camera
      end

      def resolve_camera_entities(model, entity_ids, camera_type)
        raise "No entity_ids specified for #{camera_type}" if entity_ids.empty?

        entities = []
        missing_ids = []
        entity_ids.each do |id|
          entity = model.find_entity_by_id(id)
          if entity
            entities << entity
          else
            missing_ids << id
          end
        end

        raise "No valid entities found for IDs: #{entity_ids}" if entities.empty?

        [entities, missing_ids]
      end

      def combined_bounds(entities)
        bounds = Geom::BoundingBox.new
        entities.each do |entity|
          entity_bounds = entity.respond_to?(:bounds) ? entity.bounds : nil
          next unless entity_bounds
          next if entity_bounds.respond_to?(:empty?) && entity_bounds.empty?

          bounds.add(entity_bounds.min)
          bounds.add(entity_bounds.max)
        end
        bounds
      end

      # Apply custom camera coordinates
      # @param view [Sketchup::View] the view
      # @param camera_spec [Hash] camera specification with eye, target, up
      def apply_custom_camera(view, camera_spec)
        eye = Geom::Point3d.new(*camera_spec['eye'])
        target = Geom::Point3d.new(*camera_spec['target'])

        # Calculate view direction to check for parallel vectors
        view_direction = eye.vector_to(target)

        # Determine up vector - handle parallel case for top/bottom views
        default_up = Geom::Vector3d.new(0, 0, 1)
        up = if camera_spec['up']
               Geom::Vector3d.new(*camera_spec['up'])
             elsif view_direction.parallel?(default_up)
               # Looking straight up or down - use Y axis as up
               Geom::Vector3d.new(0, 1, 0)
             else
               default_up
             end

        perspective = camera_spec['perspective'] != false
        fov = camera_spec['fov'] || 35.0

        camera = Sketchup::Camera.new(eye, target, up, perspective, fov)
        view.camera = camera
      end

      # Zoom to specific entities by ID
      # @param view [Sketchup::View] the view
      # @param model [Sketchup::Model] the model
      # @param camera_spec [Hash] camera specification with entity_ids
      def apply_zoom_entity(view, model, camera_spec)
        entity_ids = normalize_scope_entity_ids(camera_spec['entity_ids'])
        entities, missing_ids = resolve_camera_entities(model, entity_ids, 'zoom_entity')

        # Zoom to the entities
        view.zoom(entities)

        # Apply padding if specified
        padding = camera_spec['padding'] || 1.0
        apply_zoom_padding(view, padding) if padding != 1.0

        missing_ids.empty? ? [] : ["Some scope entity ids were not found: #{missing_ids.join(', ')}"]
      end

      # Apply a named standard view and frame explicit scope entities.
      # @param view [Sketchup::View] the view
      # @param model [Sketchup::Model] the model
      # @param camera_spec [Hash] camera specification with view and entity_ids
      # @return [Array<String>] warnings
      def apply_scope_standard_view(view, model, camera_spec)
        entity_ids = normalize_scope_entity_ids(camera_spec['entity_ids'])
        entities, missing_ids = resolve_camera_entities(model, entity_ids, 'scope_standard_view')

        bounds = combined_bounds(entities)
        apply_standard_view(view, model, camera_spec['view'], bounds)
        view.zoom(entities)

        padding = camera_spec['padding'] || 1.05
        apply_zoom_padding(view, padding) if padding != 1.0

        missing_ids.empty? ? [] : ["Some scope entity ids were not found: #{missing_ids.join(', ')}"]
      end

      # Apply zoom padding by adjusting camera distance
      # @param view [Sketchup::View] the view
      # @param padding [Float] padding factor (1.0 = no change, 1.2 = 20% margin)
      def apply_zoom_padding(view, padding)
        camera = view.camera
        if camera.perspective?
          # For perspective, move camera back
          direction = camera.direction
          eye = camera.eye
          target = camera.target
          distance = eye.distance(target)
          new_distance = distance * padding
          new_eye = target.offset(direction.reverse, new_distance)
          camera.set(new_eye, target, camera.up)
        else
          # For parallel projection, increase height
          camera.height = camera.height * padding
        end
        view.camera = camera
      end

      # ==========================================================================
      # Isolation State Management (Hide Rest of Model)
      # ==========================================================================

      # Save current edit context and rendering state for isolation
      # @param model [Sketchup::Model] the model
      # @return [Hash] saved isolation state
      def save_isolation_state(model)
        {
          active_path: model.active_path,
          inactive_hidden: model.rendering_options['InactiveHidden'],
          instance_hidden: model.rendering_options['InstanceHidden']
        }
      end

      # Restore edit context and rendering state after isolation
      # @param model [Sketchup::Model] the model
      # @param state [Hash] saved isolation state
      def restore_isolation_state(model, state)
        model.active_path = state[:active_path]
        model.rendering_options['InactiveHidden'] = state[:inactive_hidden]
        model.rendering_options['InstanceHidden'] = state[:instance_hidden]
      end

      # Apply isolation - open entity for editing and hide rest of model
      # @param model [Sketchup::Model] the model
      # @param entity_id [Integer] entity ID to isolate
      def apply_isolation(model, entity_id)
        entity = model.find_entity_by_id(entity_id)
        raise "Entity not found for isolation: #{entity_id}" unless entity

        # Entity must be a Group or ComponentInstance
        unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          raise "Can only isolate Group or ComponentInstance, got: #{entity.class}"
        end

        # Build full instance path from root to entity (required for nested groups)
        path = build_instance_path(entity)
        instance_path = Sketchup::InstancePath.new(path)
        model.active_path = instance_path

        # Enable "Hide rest of Model" and "Hide similar components"
        model.rendering_options['InactiveHidden'] = true
        model.rendering_options['InstanceHidden'] = true
      end

      # Build instance path from root to entity by walking up parent hierarchy
      # @param entity [Sketchup::Entity] target entity (Group or ComponentInstance)
      # @return [Array<Sketchup::Entity>] path from root to entity
      def build_instance_path(entity)
        path = [entity]
        current = entity

        # Walk up the parent hierarchy until we reach model.entities
        while current.parent.is_a?(Sketchup::ComponentDefinition)
          # Get the definition that contains current entity
          definition = current.parent
          # Get the instance of this definition (for groups, there's exactly one)
          parent_instance = definition.instances.first
          break unless parent_instance

          path.unshift(parent_instance)
          current = parent_instance
        end

        path
      end

      # ==========================================================================
      # Camera State Management
      # ==========================================================================

      # Save camera state for later restoration
      # @param camera [Sketchup::Camera] the camera
      # @return [Hash] saved camera state
      def save_camera_state(camera)
        {
          eye: camera.eye.to_a,
          target: camera.target.to_a,
          up: camera.up.to_a,
          fov: camera.fov,
          perspective: camera.perspective?,
          height: camera.perspective? ? nil : camera.height
        }
      end

      # Restore camera to saved state
      # @param view [Sketchup::View] the view
      # @param state [Hash] saved camera state
      def restore_camera_state(view, state)
        eye = Geom::Point3d.new(*state[:eye])
        target = Geom::Point3d.new(*state[:target])
        up = Geom::Vector3d.new(*state[:up])

        camera = Sketchup::Camera.new(eye, target, up, state[:perspective], state[:fov])
        camera.height = state[:height] unless state[:perspective]
        view.camera = camera
      end

      # Write screenshot to file
      # @param view [Sketchup::View] the view
      # @param filepath [String] output file path
      # @param width [Integer] image width
      # @param height [Integer] image height
      # @param transparent [Boolean] use transparent background
      def write_screenshot(view, filepath, width, height, transparent)
        FileUtils.mkdir_p(File.dirname(filepath))

        # Force view update to apply rendering options (InactiveHidden, InstanceHidden)
        # This is required because write_image may render before options are applied
        view.invalidate

        options = {
          filename: filepath,
          width: width,
          height: height,
          antialias: true,
          compression: 0.9,
          transparent: transparent
        }

        view.write_image(options)
      end

      # Prepare and validate output directory
      # @param output_dir [String, nil] requested output directory
      # @param workspace [String, nil] workspace path for default directory
      # @return [String] resolved output directory path
      # @raise [PathPolicy::PathAccessDenied] if output_dir is outside allowed roots
      def prepare_output_dir(output_dir, workspace)
        dir = if output_dir
                resolved = File.expand_path(output_dir)
                PathPolicy.validate!(resolved, operation: 'batch_screenshot', workspace: workspace)
                resolved
              else
                timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
                File.join(PathPolicy.default_tmp_dir(workspace), 'batch_screenshots', timestamp)
              end
        FileUtils.mkdir_p(dir)
        dir
      end

      # Extract default parameters from params hash
      # @param params [Hash] input parameters
      # @return [Hash] default values
      def extract_defaults(params)
        {
          width: params['width'] || 1920,
          height: params['height'] || 1080,
          transparent: params['transparent'] || false
        }
      end

      # Build response hash
      # @param results [Array<Hash>] results for each shot
      # @param output_dir [String] output directory path
      # @return [Hash] response
      def build_response(results, output_dir, scope_entity_ids = [])
        successful = results.count { |r| r[:success] }
        failed = results.count { |r| !r[:success] }

        response = {
          success: failed.zero?,
          output_dir: output_dir,
          total_shots: results.length,
          successful: successful,
          failed: failed,
          results: results
        }
        response[:scope_entity_ids] = scope_entity_ids unless scope_entity_ids.empty?
        response
      end
    end
  end
end
