function [X,P,Xp,Pp,rejSamples]=statKalmanFilter(Y,A,C,Q,R,x0,P0,B,D,U,outlierRejection,fastFlag)
%filterStationary implements a Kalman filter assuming
%stationary (fixed) noise matrices and system dynamics
%The model is: x[k+1]=A*x[k]+b+v[k], v~N(0,Q)
%y[k]=C*x[k]+d+w[k], w~N(0,R)
%And X[0] ~ N(x0,P0) -> Notice that this is different from other
%implementations, where P0 is taken to be cov(x[0|-1]) so x[0]~N(x0,A*P0*A'+Q)
%See for example Ghahramani and Hinton 1996
%Fast implementation by assuming that filter's steady-state is reached after 20 steps
%INPUTS:
%
%fastFlag: flag to indicate if fast smoothing should be performed. Default is no. Empty flag means no, any other value is yes.
%OUTPUTS:
%
%See also: statKalmanSmoother, statKalmanFilterConstrained, KFupdate, KFpredict

%TODO: check relative size of R,P and use the more efficient kalman update
%for each case. Will need to check if P is invertible, which will generally
%be the case if Q is invertible. If not, probably need to do the
%conventional update too.

%For the filter to be well-defined, it appears necessary that the quantity C'*inv(R+C*P*C')*y
%be well defined, for all observations y (with some reasonable definition of inv()).
%However, it is easy to prove [PROOF?] that only C'*inv(R+C*P*C')*z needs to be
%defined, where z=C*pinv(C)*y (that is, the projection of the observations
%onto the span of C, which is always well-defined). Thus, this can be
%simplified to requiring C'*inv(R+C*P*C') to be well-defined. Notice this 
%does not require inv(R+C*P*C') to be well defined, although that is sufficient.
% This is always the case if R is invertible, because R,P are psd matrices.
% There may exist situations where this is well defined even if R and
% R+C*P*C' are not invertible.


[D2,N]=size(Y);
D1=size(A,1);
%Init missing params:
if nargin<6 || isempty(x0)
  x0=zeros(D1,1); %Column vector
end
if nargin<7 || isempty(P0)
  P0=1e8 * eye(size(A));
end
if nargin<8 || isempty(B)
  B=0;
end
if nargin<9 || isempty(D)
  D=0;
end
if nargin<10 || isempty(U)
  U=zeros(size(B,2),size(X,2));
end
if nargin<11 || isempty(outlierRejection)
    outlierRejection=false;
end
if nargin<12 || isempty(fastFlag)
    M=N; %Do true filtering for all samples
elseif any(any(isnan(Y)))
  warning('statKFfast:NaNsamples','Requested fast KF but some samples are NaN, not using fast mode.')
  M=N;
elseif fastFlag==0
    M2=20; %Default for fast filtering: 20 samples
    M1=ceil(3*max(-1./log(abs(eig(A))))); %This many strides ensures ~convergence of gains before we assume steady-state
    M=max(M1,M2);
    M=min(M,N); %Prevent more than N, if this happens, we are not doing fast filtering
else
    M=min(ceil(abs(fastFlag)),N); %If fastFlag is a number but not 0, use that as number of samples
end

%Special case: deterministic system, no filtering needed. This can also be
%the case if Q << C'*R*C, and the system is stable
% if all(Q(:)==0)
%     [~,Xp]=fwdSim(U,A,B,C,D,x0,[],[]);
%     Ndim=size(x0,1);
%     Pp=zeros(Ndim,Ndim,N+1);
%     X=Xp(:,1:end-1);
%     P=zeros(Ndim,Ndim,N);
%     rejSamples=[];
%     return
% end

%Size checks:
%TODO

if M<N && any(abs(eig(A))>1)
    %If the system is unstable, there is no guarantee that the kalman gain
    %converges, and the fast filtering will lead to divergence of estimates
    warning('statKSfast:unstable','Doing steady-state (fast) filtering on an unstable system. States will diverge. Doing traditional filtering instead.')
    M=N;
end

%Init arrays:
if isa(Y,'gpuArray') %For code to work on gpu
    Xp=nan(D1,N+1,'gpuArray');
    X=nan(D1,N,'gpuArray');
    Pp=nan(D1,D1,N+1,'gpuArray');
    P=nan(D1,D1,N,'gpuArray');
    rejSamples=zeros(D2,N,'gpuArray');
else
    Xp=nan(D1,N+1);
    X=nan(D1,N);
    Pp=nan(D1,D1,N+1);
    P=nan(D1,D1,N);
    rejSamples=zeros(D2,N);
end

%Priors:
tol=1e-8;
prevX=x0;
prevP=P0;
Xp(:,1)=x0;
Pp(:,:,1)=P0;

%Pre-computing for speed:
%TODO: this needs to be done only if D2>D1, otherwise it is cheaper to do
%the standard Kalman update
Rinv=pinv(R,tol);
CtRinv=C'*Rinv; %gpu-ready  %Equivalent to lsqminnorm(R,C,tol)';, not gpu ready
CtRinvC=CtRinv*C; %Should use cholcov()

Y_D=Y-D*U;
CtRinvY=CtRinv*Y_D;
BU=B*U;

%Do the true filtering for M steps
for i=1:M
  %First, do the update given the output at this step:
  CiRy=CtRinvY(:,i);
  if ~any(isnan(CiRy)) %If measurement is NaN, skip update.
      if outlierRejection
          [prevXt,prevPt,z]=KFupdateAlt(CiRy,CtRinvC,prevX,prevP);
          if z<th %zscore is less than the outlier threshold, doing update
              prevP=prevPt;
              prevX=prevXt;
          end
      else %This is here because it is more efficient to not compute the z-score if we dont need it
         [prevX,prevP]=KFupdateAlt(CiRy,CtRinvC,prevX,prevP);
      end
  end
  X(:,i)=prevX;
  P(:,:,i)=prevP;

  %Then, predict next step:
  [prevX,prevP]=KFpredict(A,Q,prevX,prevP,BU(:,i));
  Xp(:,i+1)=prevX;
  Pp(:,:,i+1)=prevP;
end

%Do the fast filtering for any remaining steps:
if M<N
    %Steady-state matrices:
    Psteady=prevP; %Steady-state predicted uncertainty matrix
    iPsteady=prevP\eye(size(prevP));
    Ksteady=(iPsteady+CtRinvC)\iPsteady;
    innov=(iPsteady+CtRinvC)\CtRinvY;
    P(:,:,M+1:end)=repmat(P(:,:,M),1,1,size(Y,2)-M);
    %Pre-compute matrices to reduce computing time:
    KBUY=Ksteady*BU+innov;
    KA=Ksteady*A;
    %Loop for remaining steps:
    if outlierRejection
        %TODO: reject outliers by replacing with NaN in KBUY, this needs to
        %be done in-loop
       warning('Outlier rejection not implemented')
    end
    for i=M+1:size(Y,2)
        kbuy=KBUY(:,i);
        if ~any(isnan(kbuy))
            prevX=KA*prevX+kbuy; %Predict+Update
        else %Reading is NaN, just update. Should never happen since data with NaNs prevents fast filtering.
            prevX=A*prevX+BU(:,i);
            warning('Skipping update for a NaN sample, but uncertainty does not get updated accordingly in fast mode. FIX.')
        end
        X(:,i)=prevX;
    end
    %Compute Xp, Pp if requested:
    if nargout>2
        Xp(:,2:end)=A*X+B*U;
        Pp(:,:,M+2:end)=repmat(Psteady,1,1,size(Y,2)-M);
    end
end
end
