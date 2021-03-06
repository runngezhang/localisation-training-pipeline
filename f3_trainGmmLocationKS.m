function f3_trainGmmLocationKS(preset, featureType, azRes)
%f3_trainGmmLocationKS  Sound localisation using Gaussian mixture models
%
%   USAGE
%       f3_trainGmmLocationKS(channel, preset, featureType, azRes)
%
%   INPUT PARAMETERS
%       channel     - channel number for training. Useful for parellel training
%       preset      - 'MCT-DIFFUSE' for multi-conditional training or
%                     'CLEAN' for clean training
%       featureType - 'itd-ild' or 'cc-ild'
%       azRes       - azimuth resolution for training GMMs

%
% Ning Ma, 29 Jan 2015
%

if nargin < 3
    azRes = 5;
end
if nargin < 2
    featureType = 'itd-ild'; % 'itd-ild' or 'cc-ild'
end
if nargin < 1
    preset = 'MCT-DIFFUSE'; % 'CLEAN';
end

% Parameters
nMix = 16;


%% Setup software
%
% Add local tools
addpath Tools
% Add Netlab for GMMs
addpath(fullfile('Tools', 'GMM_Netlab'));
% Reset internal states of random number generator. This allows to use
% different settings, while still obtaining the "same" random matrix with
% sound source positions.
try
    % Since MATLAB 2011a
    rng(0);
catch
    % For older versions
    rand('seed',0);
end


%% Folder assignment
%
% Local folder for learned model storage
dirData = fullfile('learned_models', 'GmmLocationKS');
if ~exist(dirData, 'dir')
    mkdir(dirData);
end
% Tmp folders for training features
[dirFeat, dirFeatDev] = getTmpDirTraining(preset, azRes);
if ~exist(dirFeat)
    error(['Please run first f1_createBinauralFeatureTrain() and ', ...
           'f2_processBinauralFeatureTrain() in order to create missing features.']);
end
if ~exist(dirFeatDev)
    error(['Please run first f1_createBinauralFeatureDev() and ', ...
           'f2_processBinauralFeatureDev() in order to create missing features.']);
end


%% Setup GMMs
%
% Re-scale GMMs after normalization, such that no normalization has to be
% performed during testing
bRescaleGMM = false;
% Normalize feature space prior to training
bNormalize = true;
% Normalization methods ('mean','var','meanvar' or 'max')
normMethod = 'meanvar';
% GMM method
methodGMM = 'netlab';
% Represenation of covariance matrix ('spherical','diag','full' or 'ppca')
covarType = 'diag';
% EM convergence criterion
terminationEM = 1e-5;
% Number of EM iteration steps
nIterEM = 5;
% Covariance floor
floorCV = eps;

load(fullfile(dirFeat, preset));
nAzimuths = numel(R.azimuth);
nChannels = R.GFB.nFilter;

% Model name
strClassifier = sprintf('GMM_%s_%s_%ddeg_%dchannels_%dmix', preset, featureType, azRes, nChannels, nMix);
if bNormalize
    strClassifier = strcat(strClassifier,'_Norm');
end

% Initialise classifier
C = struct('ftrType', featureType, ...
           'nMix', nMix, ...
           'covarType',covarType, ...
           'bRescaleGMM',bRescaleGMM, ...
           'bNormalize',bNormalize, ...
           'normMethod',normMethod, ...
           'featNorm', {cell(nChannels,1)}, ...
           'AFE_param', R.AFE_param, ...
           'AFE_requestMix', {R.AFE_requestMix}, ...
           'nAzimuths', nAzimuths, ...
           'azimuths', R.azimuth);

if bNormalize && bRescaleGMM
    C = rmfield(C, 'featNorm');
end
logEM    = cell(nChannels, 1);
gmmFinal = cell(nChannels, 1);
[C.trainErrors, C.devErrors] = deal(zeros(nChannels, 1));

% Work out which features to include
features = strsplit(featureType, '-');
featureIdx = []; % 36dim: [itd(1) ild(1) cc(33) ic(1)]
for n = 1:length(features)
    switch lower(features{n})
        case 'itd'
            featureIdx = [featureIdx 1];
        case 'ild'
            featureIdx = [featureIdx 2];
        case 'cc'
            featureIdx = [featureIdx 3:35];
        case 'ic'
            featureIdx = [featureIdx 36];
    end
end

for ch = 1:nChannels
    fprintf('\n==== Training GMM (%d mix) for channel %d\n', nMix, ch);

    fprintf('Loading train set... ');
    strFeatNN = fullfile(dirFeat, sprintf('%s_channel%d', preset, ch));
    load(strFeatNN);
    train_x = train_x(:,featureIdx);
    normFactors = normFactors(:,featureIdx);
    fprintf('done. Loaded %d x %d features (%s)\n', ...
            size(train_x,1), size(train_x,2), featureType);
    fprintf('Loading dev set... ');
    strFeatDev = fullfile(dirFeatDev, sprintf('%s_channel%d', preset, ch));
    load(strFeatDev);
    dev_x = dev_x(:,featureIdx);
    fprintf('done. Loaded %d x %d features (%s)\n', ...
            size(dev_x,1), size(dev_x,2), featureType);
    fprintf('Training GMMs... ');
    C.featNorm{ch} = normFactors;
    [~,train_y] = max(train_y,[],2);
    [gmmFinal{ch}, logEM{ch}] = trainGMM(train_x, train_y, methodGMM, nMix, nIterEM, ...
                                         terminationEM, covarType, floorCV);
    fprintf('done.\n');

    fprintf('Validating... ');
%     % Validating using train set
%     prob = classifyGMM(train_x, gmmFinal{ch});
%     [~,labs] = max(prob,[],2);
%     C.trainErrors(ch) = sum(labs ~= train_y) / size(train_x, 1);
%     fprintf(' train error: %.4f;', C.trainErrors(ch));

    % Validating using dev set
    [~,dev_y] = max(dev_y,[],2);
    prob = classifyGMM(dev_x, gmmFinal{ch});
    [~,labs] = max(prob,[],2);
    azRef = C.azimuths(dev_y);
    azEst = C.azimuths(labs);
    azDist = calc_azimuth_distance(azRef, azEst);
    nDevFrames = size(dev_x, 1);
    C.devError(ch) = sum(azDist > 5) / nDevFrames;
    fbErrors = (sum((azRef + azEst) == 180) + sum((azRef + azEst) == 540)) / nDevFrames;
    fprintf(' dev error: %.3f%%, FB error: %.3f%%\n', C.devError(ch)*100, fbErrors*100);

end

C.gmmFinal = gmmFinal;

% Store GMM classifier
saveStr = fullfile(dirData, strClassifier);
save([saveStr, '.mat'], 'C');

% vim: set sw=4 ts=4 et tw=90:
