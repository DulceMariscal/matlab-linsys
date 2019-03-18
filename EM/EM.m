function [A,B,C,D,Q,R,X,P,bestLogL,outLog]=EM(Y,U,Xguess,opts,Pguess)
%A true EM implementation to do LTI-SSM identification
%INPUT:
%Y is D2 x N
%U is D3 x N
%Xguess - Either the number of states for the system (if scalar) or a guess
%at the initial states of the system (if D1 x N matrix)

%Scaling: (Note: scaling is not important to EM, the optimal solution is
%scale invariant. However, some constants here have been fine-tuned
%presuming a certain scaling of the data for convergence issues.)
%Is this a good idea? While the optimal model is scale-invariant, the log-L
%is NOT. As long as every comparison of log-L is made across equally-scaled
%data, this is fine. Other comparisons will not be appropriate. Does that
%ever happen?
if ~isa(Y,'cell')
    scale=sqrt(nanmean(Y.^2,2)); %Should I normalize to the variance instead of the second moment?
    Y=Y./scale;
    if ~isempty(opts.fixC)
      opts.fixC=opts.fixC./scale;
    end
    if ~isempty(opts.fixD)
      opts.fixD=opts.fixD./scale;
    end
    if ~isempty(opts.fixR)
      opts.fixR=opts.fixR./(scale.*scale');
    end
else
    scale=sqrt(nanmean(cell2mat(Y).^2,2)); %Single scale for all data
    Y=cellfun(@(x) x./scale,Y,'UniformOutput',false);
    if ~isempty(opts.fixC)
      opts.fixC=opts.fixC./scale;
    end
    if ~isempty(opts.fixD)
      opts.fixD=opts.fixD./scale;
    end
    if ~isempty(opts.fixR)
      opts.fixR=opts.fixR./(scale.*scale');
    end
end
%Would randomly changing the scale every N iterations help in convergence speed? Maybe get unstuck from local saddles?

if nargin<4
    opts=[];
end
if nargin<5
    if ~isa(Y,'cell')
        Pguess=[];
    else
        Pguess=cell(size(Y));
    end
end
outLog=[];

%Process opts:
if isa(U,'cell')
  Nu=size(U{1},1);
else
  Nu=size(U,1);
end
[opts] = processEMopts(opts,Nu); %This is a fail-safe to check for proper options being defined.
if opts.fastFlag~=0 && ( (~isa(Y,'cell') && any(isnan(Y(:)))) || (isa(Y,'cell') && any(any(isnan(cell2mat(Y)))) ) )
   warning('EM:fastAndLoose','Requested fast filtering but data contains NaNs. No steady-state can be found for filtering. Filtering will not be exact, log-L is not guaranteed to be non-decreasing (disabling warning).')
   warning('off','EM:logLdrop') %If samples are NaN, fast filtering may make the log-L drop (smoothing is not exact, so the expectation step is not exact)
  %opts.fastFlag=0; %No fast-filtering in nan-filled data
elseif opts.fastFlag~=0 && opts.fastFlag~=1
    warning('EM:fastFewSamples','Requested an exact number of samples for fast filtering. This is guaranteed to be equivalent to fast filtering only if the slowest time-constant of the system is much smaller than the requested number of samples, otherwise this is an appoximation.')
end
if opts.logFlag
  %diary(num2str(round(now*1e5)))
  outLog.opts=opts;
  tic
end
if opts.fastFlag~=0
%Disable some annoying warnings related to fast filtering (otherwise these
%warnings appear on each iteration when the Kalman filter is run):
warning('off','statKFfast:unstable');
warning('off','statKFfast:NaN');
warning('off','statKSfast:unstable');
warning('off','statKSfast:fewSamples');
end

%% ------------Init stuff:-------------------------------------------
% Init params:
 [A1,B1,C1,D1,Q1,R1,x01,P01]=initEM(Y,U,Xguess,opts,Pguess);
 [X1,P1,Pt1,~,~,~,~,~,bestLogL]=statKalmanSmoother(Y,A1,C1,Q1,R1,x01,P01,B1,D1,U,opts);

%Initialize log-likelihood register & current best solution:
logl=nan(opts.Niter,1);
logl(1)=bestLogL;
if isa(Y,'gpuArray')
    logl=nan(Niter,1,'gpuArray');
end
A=A1; B=B1; C=C1; D=D1; Q=Q1; R=R1; x0=x01; P0=P01; P=P1; Pt=Pt1; X=X1;

%Initialize target logL:
if isempty(opts.targetLogL)
    opts.targetLogL=logl(1);
end
%figure;
%hold on;
%% ----------------Now, do E-M-----------------------------------------
breakFlag=false;
improvement=true;
%initialLogLgap=opts.targetLogL-bestLogL;
nonNaNsamples=sum(~any(isnan(Y),1));
disp(['Iter = 1, target logL = ' num2str(opts.targetLogL,8) ', current logL=' num2str(bestLogL,8) ', \tau =' num2str(-1./log(sort(eig(A)))')])
for k=1:opts.Niter-1
	%E-step: compute the distribution of latent variables given current parameter estimates
	%M-step: find parameters A,B,C,D,Q,R that maximize likelihood of data

    %Save to log:
    if opts.logFlag
        outLog.vaps(k,:)=sort(eig(A1));
        outLog.logL=logl(k);
        outLog.runTime(k)=toc;
        tic;
    end

    %E-step:
    if isa(Y,'cell') %Data is many realizations of same system
        [X1,P1,Pt1,~,~,~,~,~,l1]=cellfun(@(y,x0,p0,u) statKalmanSmoother(y,A1,C1,Q1,R1,x0,p0,B1,D1,u,opts),Y,x01,P01,U,'UniformOutput',false);
        if any(cellfun(@(x) any(imag(x(:))~=0),X1))
          msg='Complex states detected, stopping.';
          breakFlag=true;
        elseif any(cellfun(@(x) isnan(sum(x(:))),X1))
          msg='States are NaN, stopping.';
          breakFlag=true;
        end
        sampleSize=cellfun(@(y) size(y,2),Y);
        l=(cell2mat(l1)*sampleSize')/sum(sampleSize);
    else
        [X1,P1,Pt1,~,~,~,~,~,l]=statKalmanSmoother(Y,A1,C1,Q1,R1,x01,P01,B1,D1,U,opts);
        if any(imag(X1(:))~=0)
            msg='Complex states detected, stopping.';
            breakFlag=true;
        elseif isnan(sum(X1(:)))
            msg='States are NaN, stopping.';
            breakFlag=true;
        end
    end


    %Check improvements:
    %There are three stopping criteria:
    %1) number of iterations
    %2) improvement in logL per dimension of output less than some threshold. It makes sense to do it per dimension of output because in high-dimensional models, the number of parameters of the model is roughly proportional to the number of output dimensions. IDeally, this would be done per number of free model parameters, so it has a direct link to significant improvements in log-L (Wilk's theorem suggests we should expect an increase in logL of 1 per each extra free param, so when improvement is well below this, we can stop).
    %3) relative improvement towards target value. The idea is that logL may be increasing fast according to criterion 2, but nowhere fast enough to ever reach the target value.
    logl(k+1)=l;
    delta=l-logl(k);
    improvement=delta>=0;
    logL100ago=logl(max(k-100,1),1);
    targetRelImprovement100=(l-logL100ago)/(opts.targetLogL-logL100ago);
    belowTarget=max(l,bestLogL)<opts.targetLogL;
    relImprovementLast100=l-logL100ago; %Assessing the improvement on logl over the last 50 iterations (or less if there aren't as many)

    %Check for warning conditions:
    if ~improvement %This should never happen
        %Drops in logL may happen when using fast filtering in
        %conjunction with the presence of NaN samples. In that case, there
        %is no steady-state for the Kalman filter/smoother, and thus
        %filtering is approximate/not-optimal.
         %Drops of 1e-9 to 1e-8 happen even without NaN samples, specially if number of samples is not too large and model order is. This may be a numerical issue.
        if abs(delta)>1e-7
          %Report only if drops are larger than this. This value probably is sample-size dependent, so may need adjusting.
          warning('EM:logLdrop',['logL decreased at iteration ' num2str(k) ', drop = ' num2str(delta)])
        end
    end

    %Check for failure conditions:
    if imag(l)~=0 %This does not happen
        msg='Complex logL, probably ill-conditioned matrices involved. Stopping.';
        breakFlag=true;
    elseif l>=bestLogL %There was improvement
        %If everything went well and these parameters are the best ever:
        %replace parameters  (notice the algorithm may continue even if
        %the logl dropped, but in that case we do not save the parameters)
        A=A1; B=B1; C=C1; D=D1; Q=Q1; R=R1; x0=x01; P0=P01; X=X1; P=P1; Pt=Pt1;
        bestLogL=l;
    end

    %Check if we should stop early (to avoid wasting time):
    if k>100 && (belowTarget && (targetRelImprovement100)<opts.targetTol) && ~opts.robustFlag%Breaking if improvement less than tol of distance to targetLogL
       msg='Unlikely to reach target value. Stopping.';
       breakFlag=true;
    elseif k>100 && (relImprovementLast100*nonNaNsamples)<opts.convergenceTol && ~opts.robustFlag %Considering the system stalled if relative improvement on logl is <tol
        msg='Increase is within tolerance (local max). Stopping.';
        breakFlag=true;
    elseif k==opts.Niter-1
        msg='Max number of iterations reached. Stopping.';
        breakFlag=true;
    end

    %Print some info
    step=100;
    if mod(k,step)==0 || breakFlag %Print info
        pOverTarget=100*((l-opts.targetLogL)/abs(opts.targetLogL));
        if k>=step && ~breakFlag
            lastChange=l-logl(k+1-step,1);
            %disp(['Iter = ' num2str(k)  ', logL = ' num2str(l,8) ', \Delta logL = ' num2str(lastChange,3) ', % over target = ' num2str(pOverTarget,3) ', \tau =' num2str(-1./log(sort(eig(A1)))',3)])
            disp(['Iter = ' num2str(k) ', \Delta logL = ' num2str(lastChange*length(scale)*nonNaNsamples,3) ', over target = ' num2str(length(scale)*nonNaNsamples*(l-opts.targetLogL),3) ', \tau =' num2str(-1./log(sort(eig(A1)))',3)]) %This displays logL over target, not in a per-sample per-dim way (easier to probe if logL is increasing significantly)
            %sum(rejSamples)
        else %k==1 || breakFlag
            l=bestLogL;
            pOverTarget=100*((l-opts.targetLogL)/abs(opts.targetLogL));
            disp(['Iter = ' num2str(k) ', logL = ' num2str(l,8) ', % over target = ' num2str(pOverTarget) ', \tau =' num2str(-1./log(sort(eig(A)))')])
            if breakFlag; fprintf([msg ' \n']); end
        end
    end
    if breakFlag && ~opts.robustFlag
        break
    end
    %M-step:
    [A1,B1,C1,D1,Q1,R1,x01,P01]=estimateParams(Y,U,X1,P1,Pt1,opts);
end %for loop

%%
if opts.fastFlag==0 %Re-enable disabled warnings
    warning('on','statKFfast:unstable');
    warning('on','statKFfast:NaN');
    warning('on','statKSfast:fewSamples');
    warning('on','statKSfast:unstable');
    warning('on','EM:logLdrop')
end
if opts.logFlag
  outLog.vaps(k,:)=sort(eig(A1));
  outLog.runTime(k)=toc;
  outLog.breakFlag=breakFlag;
  outLog.msg=msg;
  outLog.bestLogL=bestLogL;
  %diary('off')
end

%% Restore scale:
C=C.*scale;
D=D.*scale;
R=scale.*R.*scale';
end  %Function
