function batch_process_localizations()
    % ================= USER PARAMS =================
    DOT_SIZE = 16;  % Marker size (points) for all scatter dots in ROI views
    % ==============================================

    % Define input and output directories
    input_dir  = 'C:\Users\home\Documents\Val\new_cells';
    output_dir = 'C:\Users\home\Documents\Val\new_cells_output';
    if ~exist(output_dir, 'dir')
        mkdir(output_dir);
    end

    % Ask user for mode
    mode = questdlg('Process mode:', 'Select Mode', ...
                    'Batch (all files)', 'Single file', 'Batch (all files)');

    if strcmp(mode, 'Single file')
        % Single file mode
        [filename, filepath] = uigetfile(fullfile(input_dir, '*_retained.txt'), ...
                                         'Select file to process');
        if isequal(filename, 0)
            fprintf('No file selected. Exiting.\n');
            return;
        end
        full_filepath = fullfile(filepath, filename);
        fprintf('\n========================================\n');
        fprintf('Processing single file: %s\n', filename);
        fprintf('========================================\n');
        process_single_file(full_filepath, output_dir, filename, DOT_SIZE);
        fprintf('\nProcessing complete!\n');
    else
        % Batch mode - original behavior
        txt_files = dir(fullfile(input_dir,'*_retained.txt'));

        % Ask for starting point
        start_idx = 1;
        if numel(txt_files) > 1
            prompt = sprintf('Enter starting file number (1-%d) or press Enter to start from beginning: ', numel(txt_files));
            user_input = input(prompt, 's');
            if ~isempty(user_input)
                start_idx = str2double(user_input);
                if isnan(start_idx) || start_idx < 1 || start_idx > numel(txt_files)
                    start_idx = 1;
                end
            end
        end

        for idx = start_idx:numel(txt_files)
            filename = txt_files(idx).name;
            filepath = fullfile(input_dir, filename);
            fprintf('\n========================================\n');
            fprintf('Processing file %d/%d: %s\n', idx, numel(txt_files), filename);
            fprintf('========================================\n');
            process_single_file(filepath, output_dir, filename, DOT_SIZE);
            if idx < numel(txt_files)
                resp = input('Continue to next file? (y/n): ', 's');
                if isempty(resp) || ~strcmpi(resp,'y')
                    fprintf('Batch processing stopped by user.\n');
                    break;
                end
            end
        end
        fprintf('\nBatch processing complete!\n');
    end
end

% -------------------------------------------------------------------------
function process_single_file(filepath, output_dir, filename, dotSize)
    data = readtable(filepath,'Delimiter','\t');
    original_count = height(data);
    if ~all(ismember({'x','y'}, data.Properties.VariableNames))
        error('File must contain x and y columns.');
    end
    original_columns = data.Properties.VariableNames;

    xmin = min(data.x); xmax = max(data.x);
    ymin = min(data.y); ymax = max(data.y);
    dx = 0.05*(xmax - xmin + eps);
    dy = 0.05*(ymax - ymin + eps);
    xlims = [xmin - dx, xmax + dx];
    ylims = [ymin - dy, ymax + dy];

    %% Step 1: Periphery selection using polygon ROI
    fprintf('\nSTEP 1 — Click points around CELL PERIPHERY, then press Enter or click Accept\n');
    peripheryPos = [];
    while true
        [peripheryPos, periphery_area_nm2, didCancel] = draw_polygon_roi(data, xlims, ylims, ...
            'STEP 1: Click vertices for periphery polygon', dotSize);
        if ~didCancel && ~isempty(peripheryPos)
            break;
        end
        choice = questdlg(sprintf('Periphery not finalized for:\n  %s\n\nRetry, Skip file, or Abort batch?', filename), ...
                           'Periphery Selection','Retry','Skip','Abort','Retry');
        switch choice
            case 'Retry'
                % continue loop
            case 'Skip'
                fprintf('Skipping file (no periphery): %s\n', filename);
                return;
            otherwise
                error('Batch aborted by user (no periphery selected).');
        end
    end
    periphery_area_um2 = periphery_area_nm2 / 1e6;
    fprintf('Periphery area: %.2f µm²\n', periphery_area_um2);

    % Save periphery outline immediately
    periphery_outline_file = save_outline_points(output_dir, filename, peripheryPos, 'periphery');

    in_periphery = inpolygon(data.x, data.y, peripheryPos(:,1), peripheryPos(:,2));
    points_removed_outside = sum(~in_periphery);
    data = data(in_periphery, :);
    fprintf('Removed %d points outside periphery (%.1f%%)\n', points_removed_outside, 100*points_removed_outside/original_count);

    %% Step 2: Nucleus/Core (optional)
    core_area_um2 = 0;
    points_removed_core = 0;
    corePos = [];
    core_outline_file = '';
    doCore = questdlg('Select nucleus/core region?', 'Core/Nucleus Selection','Yes','No','No');
    if strcmpi(doCore,'Yes')
        [corePos, core_area_nm2, didCancel] = draw_polygon_roi(data, xlims, ylims, ...
            'STEP 2: Click vertices for nucleus/core polygon', dotSize);
        if ~didCancel && ~isempty(corePos)
            core_area_um2 = core_area_nm2 / 1e6;

            % Save nucleus/core outline
            core_outline_file = save_outline_points(output_dir, filename, corePos, 'nucleus');

            in_core = inpolygon(data.x, data.y, corePos(:,1), corePos(:,2));
            points_removed_core = sum(in_core);
            data = data(~in_core,:);
            fprintf('Nucleus/Core area: %.2f µm² | Removed %d core points\n', core_area_um2, points_removed_core);
        else
            fprintf('Nucleus/Core selection canceled/skipped; no core removed.\n');
        end
    else
        fprintf('STEP 2 skipped.\n');
    end

    %% Step 3: Additional removal (optional)
    additional_removed = 0;
    while true
        doMore = questdlg('Remove additional region(s)?','Additional Removal','Yes','No','No');
        if ~strcmpi(doMore,'Yes')
            break;
        end
        [rmPos, ~, didCancel] = draw_polygon_roi(data, xlims, ylims, ...
            'STEP 3: Click vertices for removal polygon', dotSize);
        if ~didCancel && ~isempty(rmPos)
            in_rm = inpolygon(data.x, data.y, rmPos(:,1), rmPos(:,2));
            n_rm = sum(in_rm);
            data = data(~in_rm,:);
            additional_removed = additional_removed + n_rm;
            fprintf('Removed %d additional points\n', n_rm);
        else
            fprintf('Additional removal canceled for this region.\n');
        end
    end

    %% Final area and summary
    final_area_um2 = periphery_area_um2 - core_area_um2;
    total_removed = original_count - height(data);
    fprintf('\n========== FINAL SUMMARY ==========\n');
    fprintf('Original points: %d\n', original_count);
    fprintf('Removed outside periphery: %d\n', points_removed_outside);
    fprintf('Removed inside core: %d\n', points_removed_core);
    fprintf('Additional removed: %d\n', additional_removed);
    fprintf('Total removed: %d (%.1f%%)\n', total_removed, 100*total_removed/original_count);
    fprintf('Final points remaining: %d\n', height(data));
    fprintf('Final area (periphery - core): %.2f µm²\n', final_area_um2);

    %% Save filtered results
    data = data(:, original_columns);
    output_file = fullfile(output_dir, filename);
    writetable(data, output_file, 'Delimiter', '\t');
    fprintf('Saved filtered data to: %s\n', output_file);

    %% Save summary (references outline files)
    summary_file = fullfile(output_dir, strrep(filename,'.txt','_areas.txt'));
    fid = fopen(summary_file,'w');
    fprintf(fid, 'File: %s\n', filename);
    fprintf(fid, 'Periphery area (µm^2): %.6f\n', periphery_area_um2);
    fprintf(fid, 'Core/Nucleus area (µm^2): %.6f\n', core_area_um2);
    fprintf(fid, 'Final area (µm^2): %.6f\n', final_area_um2);
    fprintf(fid, 'Original points: %d\n', original_count);
    fprintf(fid, 'Final points: %d\n', height(data));
    fprintf(fid, 'Total removed: %d\n', total_removed);
    fprintf(fid, 'Periphery outline file: %s\n', periphery_outline_file);
    fprintf(fid, 'Periphery outline vertices: %d\n', size(peripheryPos,1));
    if ~isempty(corePos)
        fprintf(fid, 'Nucleus outline file: %s\n', core_outline_file);
        fprintf(fid, 'Nucleus outline vertices: %d\n', size(corePos,1));
    else
        fprintf(fid, 'Nucleus outline file: (none)\n');
        fprintf(fid, 'Nucleus outline vertices: 0\n');
    end
    fclose(fid);
    fprintf('Saved summary to: %s\n', summary_file);
end

% -------------------------------------------------------------------------
function outfile = save_outline_points(output_dir, filename, pos, typeTag)
    % typeTag: 'periphery' or 'nucleus'
    outline_tbl = table(pos(:,1), pos(:,2), 'VariableNames', {'x','y'});
    base = strrep(filename, '.txt', '');
    switch lower(typeTag)
        case 'periphery'
            suffix = '_periphery_outline.txt';
        case 'nucleus'
            suffix = '_nucleus_outline.txt';
        otherwise
            suffix = '_outline.txt';
    end
    outfile = fullfile(output_dir, [base, suffix]);
    writetable(outline_tbl, outfile, 'Delimiter', '\t');
    fprintf('Saved %s outline (%d vertices) to: %s\n', typeTag, height(outline_tbl), outfile);
end

% -------------------------------------------------------------------------
function [pos, area_nm2, didCancel] = draw_polygon_roi(data, xlims, ylims, titleStr, dotSize)
    % ROI figure with polygon selection (no text overlays)
    pos = [];
    area_nm2 = 0;
    didCancel = false;

    hFig = figure('Color','w','Name',titleStr, ...
                  'Position',[100 100 900 820], 'NumberTitle','off', ...
                  'MenuBar','none','ToolBar','none');
    ax = axes('Parent',hFig,'Position',[0.08 0.12 0.88 0.80]);

    % Plot the data points (bigger dots via dotSize)
    sc = scatter(ax, data.x, data.y, dotSize, [0 0 1], 'filled');
    set(sc, 'MarkerFaceAlpha', 0.3, 'MarkerEdgeAlpha', 0.3);
    hold(ax, 'on');

    axis(ax,'equal'); grid(ax,'on');
    xlim(ax, xlims); ylim(ax, ylims);
    title(ax, sprintf('%s\n(Enter=Accept, Esc/q=Cancel)', titleStr), 'Interpreter','none');

    % Buttons
    uicontrol('Parent',hFig,'Style','pushbutton','String','Accept (Enter)', ...
              'Units','normalized','Position',[0.08 0.02 0.18 0.06], ...
              'FontSize',11,'BackgroundColor',[0.85 1 0.85], ...
              'Callback',@(s,e)set(hFig,'UserData','accept'));
    uicontrol('Parent',hFig,'Style','pushbutton','String','Cancel (Esc/q)', ...
              'Units','normalized','Position',[0.28 0.02 0.18 0.06], ...
              'FontSize',11,'BackgroundColor',[1 0.85 0.85], ...
              'Callback',@(s,e)set(hFig,'UserData','cancel'));

    % Polygon ROI (Image Processing Toolbox)
    roi = drawpolygon(ax, 'Color',[1 0 0], 'LineWidth',2, 'FaceAlpha',0.1);

    set(hFig,'WindowKeyPressFcn', @(src,ev) keyHandler(src,ev));
    waitfor(hFig,'UserData');
    outcome = get(hFig,'UserData');

    if isgraphics(roi)
        verts = roi.Position;
    else
        verts = [];
    end

    switch outcome
        case 'accept'
            if ~isempty(verts) && size(verts,1) >= 3
                pos = verts;
                area_nm2 = polyarea(pos(:,1), pos(:,2));
            else
                didCancel = true;
            end
        otherwise
            didCancel = true;
    end

    if isgraphics(hFig)
        close(hFig);
    end

    function keyHandler(fig, ev)
        switch lower(ev.Key)
            case {'return','enter'}
                set(fig,'UserData','accept');
            case {'escape','q'}
                set(fig,'UserData','cancel');
        end
    end
end
