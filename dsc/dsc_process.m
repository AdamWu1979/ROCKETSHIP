function dsc_process(dsc_image,noise_type,noise_roi_path,aif_type, aif_path,fitting_function,TE,TR,r2_star,psvd,rho,species)
    disp("starting DSC processing...");
    tic;
    
    %Unboxing the variables from the handles structure:
    deltaT = TR / 60;  % converstion to minutes.


    %Next WE ARE GOING TO LOAD THE IMAGE FILE:
    disp("input image: "+dsc_image);
    disp("species: "+species);
    disp("R2_star: "+r2_star);
    image_array = load_nii(dsc_image);
    image_array = image_array.img;
    %Next we load the nosie roi array:
    if noise_type == 0
        roi_array = [];
    elseif noise_type == 1
        roi_array = load_nii(noise_roi_path);
        roi_array = roi_array.img;
    end


    %getting the path from the image file:
    [ ~ , image_path] = fileparts(dsc_image);

    [concentration_array, base_concentration_array, time_vect, base_time_vect,whole_time_vect, bolus_time] = ...
        DSC_signal2concentration(image_array,TE,TR,r2_star,species,image_path,noise_type,roi_array );
    if aif_type == 0 %AIF Auto
        [meanAIF, meanSignal] = AIF_auto_cluster(concentration_array, image_array, time_vect, TR,species);
        baseline = 0; %develop a way to calculate the baseline from the auto clustered AIF
        baseline_array = zeros(numel(base_time_vect),1);
    elseif aif_type ==1 %AIF User Selected
        AIF_mask = load_nii(aif_path);
        AIF_mask = AIF_mask.img;
        [meanAIF, meanSignal, baseline,baseline_array] = AIF_manual_noreshape(image_array,concentration_array,AIF_mask, base_time_vect,base_concentration_array);

    elseif aif_type==2 %AIF Import
        load(aif_path)
        [meanAIF_adjusted, time_vect, concentration_array] = import_AIF(meanAIF, bolus_time, time_vect, concentration_array, r2_star, TE);
        meanAIF = meanAIF_adjusted;

        disp('time_vect_num')
        numel(time_vect)
        disp('meanAIF_num')
        numel(meanAIF)

    elseif aif_type==3 %AIF Use Previous
        load('previous_data.mat', 'meanAIF','meanSignal','bolus_time','baseline');
        [meanAIF_adjusted, time_vect, concentration_array] = previous_AIF(meanAIF,meanSignal,bolus_time, time_vect,concentration_array);
        meanAIF = meanAIF_adjusted;

        disp('time_vect_num')
        numel(time_vect)
        disp('meanAIF_num')
        numel(meanAIF)
    end

    %create a mean AIF spaning the whole scan time
    AIF_whole = cat(1,baseline_array, meanAIF);

    %now run the selected fitting function
    if fitting_function == 0 %forced linear biexponential (uses local max) %the upslope is fitted to

        Cp = cat(1,baseline_array,meanAIF);
        step = [(bolus_time) (bolus_time + numel(time_vect))];
        T1 = whole_time_vect;
        xdata = struct('Cp',Cp,'baseline', baseline, 'timer', T1, 'step', step, 'bolus_time', bolus_time);
        verbose = -1; %this prevents any internal verbose function from running change to 1 to run verbose

        [Cp, x, xdata, rsqurare] = Single_Forced_linear_AIFbiexpfithelplocal(xdata,verbose);
        Ct = Cp;
        Ct(1:bolus_time - 1) = [];
        Ct = Ct';

    elseif fitting_function == 1 %biexponential (uses absolute max)
        Cp = cat(1,baseline_array,meanAIF);
        step = [bolus_time (bolus_time + numel(time_vect))];
        T1 = whole_time_vect;
        xdata = struct('Cp',Cp,'baseline', baseline, 'timer', T1, 'step', step, 'bolus_time', bolus_time);
        verbose = -1; %this prevents any internal verbose function from running change to 1 to run verbose

        [Cp, x, xdata, rsqurare] = AIFbiexpfithelp(xdata,verbose);
        Ct = Cp;
        Ct(1:bolus_time - 1) = [];
        Ct = Ct';

    elseif fitting_function == 2 %biexponential (uses local max)
        Cp = cat(1,baseline_array,meanAIF);
        step = [bolus_time (bolus_time + numel(time_vect))];
        T1 = whole_time_vect;
        xdata = struct('Cp',Cp,'baseline', baseline, 'timer', T1, 'step', step, 'bolus_time', bolus_time);
        verbose = -1; %this prevents any internal verbose function from running change to 1 to run verbose

        [Cp, x, xdata, rsqurare] = AIFbiexpfithelplocal(xdata,verbose);
        Ct = Cp;
        Ct(1:bolus_time - 1) = [];
        Ct = Ct';

    elseif fitting_function == 3 %gamma-variant
        % Now we fit the AIF with a SCR model:

        %assigning the gamma variate function, gfun, to be our desired fitting
        %function:
        Ct = fitting_gamma_variant(meanAIF,species, time_vect);
        Cp = cat(1,baseline_array, Ct); %Cp is created for plotting purposes only. Ct is analyzed for CBF, CBV...

    elseif fitting_function == 4 %raw data
        Ct = meanAIF;
        Cp = cat(1,baseline_array, Ct);

    %{
    elseif fitting_function == 42 %copy_of_upslopewith peak based decision making (not currently an option)
        Cp = cat(1,baseline_array,meanAIF);
        step = [bolus_time (bolus_time + numel(time_vect))];
        T1 = whole_time_vect;
        xdata = struct('Cp',Cp,'baseline', baseline, 'timer', T1, 'step', step, 'bolus_time', bolus_time);
        verbose = -1; %this prevents any internal verbose function from running change to 1 to run verbose

        [Cp, x, xdata, rsqurare] = Forced_linear_AIFbiexpfithelplocal(xdata,verbose);
        Ct = Cp;
        Ct(1:bolus_time - 1) = [];
        [~,max_indexCt] = max(Ct);

        if numel(findpeaks(AIF_whole(bolus_time:((bolus_time + 1) + max_indexCt)))) == 1 %check for additional local maxima in upslope, if none
            %are present use the exact upslope vales for the fitted funciton
            Ct(1:max_indexCt) = meanAIF(1: max_indexCt);
            Ct = Ct';
            base = baseline * ones(numel(baseline_array),1);
            Cp = [base; Ct];
        else %if additional local maxima or 'bumps' in the upslope are present, use the 2 point forced linear fit
            Ct = Ct';
        end
    %}
    elseif fitting_function == 5 %copy_of_upslope with peak based decision making
        Cp = cat(1,baseline_array,meanAIF);
        step = [bolus_time (bolus_time + numel(time_vect))];
        T1 = whole_time_vect;
        xdata = struct('Cp',Cp,'baseline', baseline, 'timer', T1, 'step', step, 'bolus_time', bolus_time);
        verbose = -1; %this prevents any internal verbose function from running change to 1 to run verbose

        [Cp, x, xdata, rsqurare] = AIFbiexpfithelplocal(xdata,verbose);
        Ct = Cp;
        Ct(1:bolus_time -1) = [];

       %calculate the most likely first peak by finding the first local maxima
        %as was done in the local fitting help function
        %peak is the first within 3% of the max value of the whole data set
        [local_maxima, maxima_indexes] = findpeaks(Ct);
        maxima_iterator = 1;
        while(local_maxima(maxima_iterator) < (0.97 * max(local_maxima)))
            maxima_iterator = maxima_iterator + 1;
        end

        max_indexCt = maxima_indexes(maxima_iterator);

        if numel(findpeaks(AIF_whole(bolus_time:(bolus_time + max_indexCt)))) == 1 %check for additional local maxima in upslope, if none
            %are present use the exact upslope vales for the fitted funciton
            %[bolus time, max_index + 1] is the range that is examined for the
            %additional maxima
            Ct(1:max_indexCt) = meanAIF(1:max_indexCt);
            Ct = Ct';
            base = baseline * ones(numel(baseline_array),1);
            Cp = [base; Ct];
        else %if additional local maxima or 'bumps' in the upslope are present, use a smooth fit
            Ct = Ct';
        end

    elseif fitting_function == 6 %upslope copy biexponetial

        Cp = cat(1,baseline_array,meanAIF);
        step = [bolus_time (bolus_time + numel(time_vect))];
        T1 = whole_time_vect;
        xdata = struct('Cp',Cp,'baseline', baseline, 'timer', T1, 'step', step, 'bolus_time', bolus_time);
        verbose = -1; %this prevents any internal verbose function from running change to 1 to run verbose

        [Cp, x, xdata, rsqurare] = AIFbiexpfithelplocal(xdata,verbose);
        Ct = Cp;
        Ct(1:bolus_time - 1) = [];

        %calculate the most likely first peak by finding the first local maxima
        %as was done in the local fitting help function
        %peak is the first within 3% of the max value of the whole data set
        [local_maxima, maxima_indexes] = findpeaks(Ct);
        maxima_iterator = 1;
        while(local_maxima(maxima_iterator) < (0.97 * max(local_maxima)))
            maxima_iterator = maxima_iterator + 1;
        end

        max_indexCt = maxima_indexes(maxima_iterator);

        max_indexCt = maxima_indexes(maxima_iterator);

        %exact upslope vales for the fitted funciton
        Ct(1:max_indexCt) = meanAIF(1:max_indexCt);
        Ct = Ct';
        base = baseline * ones(numel(baseline_array),1);
        Cp = [base; Ct];

    elseif fitting_function == 7 %forced bilinear biexponential decay

        %two linear function
        Cp = cat(1,baseline_array,meanAIF);
        step = [(bolus_time) (bolus_time + numel(time_vect))];
        T1 = whole_time_vect;
        xdata = struct('Cp',Cp,'baseline', baseline, 'timer', T1, 'step', step, 'bolus_time', bolus_time);
        verbose = -1; %this prevents any internal verbose function from running change to 1 to run verbose

        [Cp, x, xdata, rsqurare] = Forced_linear_AIFbiexpfithelplocal(xdata,verbose);
        Ct = Cp;
        Ct(1:bolus_time - 1) = [];
        Ct = Ct';

    end

    %save this runs meanAIF, bolus time, and importedAIF
    save('previous_data.mat', 'meanAIF','meanSignal','bolus_time','baseline');

    %plot the meanAIF and fitted function over the entire scan
    figure;
    plot(whole_time_vect,Cp,'-o', whole_time_vect, AIF_whole);
    title('AIF and Fitted AIF Over time');
    xlabel('Time (min)');
    ylabel('Concentration (mM)');
    legend('Fitted AIF', 'Raw AIF');

    %plot the mean AIF and fitted function over the time period to be analyzed
    figure;
    time_vect_sec = time_vect * 60; %get time in seconds to plot
    time_vect_sec = time_vect_sec + (bolus_time);
    %base_time_vect_sec = base_time_vect * 60;
    plot(time_vect_sec,Ct,'-o',time_vect_sec,meanAIF);
    title('AIF and Fitted AIF Over time');
    xlabel('Time (s)');
    ylabel('Concentration (mM)');
    legend('Fitted AIF', 'Raw AIF');

    %plot the mean AIF signal
    figure;
    time_vect_sec2 = 0 : length(meanSignal) -1;
    time_vect_sec2 = time_vect_sec2 * TR;
    plot(time_vect_sec2, meanSignal, 'b');
    title('AIF Mean Signal from Start to End of Scan')
    xlabel('Time (s)')
    ylabel('Signal Intensity (au)')

    Kh = 0.71;
    % method = 1;
    [CBF, CBV, MTT] = DSC_convolution_sSVD(concentration_array,Ct,deltaT,Kh,rho,psvd,1,image_path);
    disp('finished DSC processing!');
    toc;
end