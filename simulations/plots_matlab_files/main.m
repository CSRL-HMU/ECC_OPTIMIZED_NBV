clear all; 
close all;
clc;
global L  g  b  m dt;

g = 9.81;  % gravitational acceleration (m/s^2)
L = 1;     % length of the pendulum (m)
b = 0.04;
m = 1;
dt = 0.033;
kappa = 0;


% Measurement Noise (R matrix in Bibliography)
SIGMA_normal = [0.01, 0,     0;
                0,    0.01,  0;
                0,    0,     0.2];

increased_SIGMA = [5000, 0,     0;
                 0,    5000,  0;
                 0,    0,     5000];

% Process Noise (Q matrix)
Q = [0.02, 0,     0,     0,     0,     0;
     0,    0.001, 0,     0,     0,     0;
     0,    0,     0.001, 0,     0,     0;
     0,    0,     0,     0.1,   0,     0;
     0,    0,     0,     0,     0.01,  0;
     0,    0,     0,     0,     0,     0.01];

% Compute the square root of the sum across columns (equivalent to Q @ ones(6) in Python)
Qdiag = sqrt(Q * ones(6,1));

% State vector (ensure L is defined in your workspace)
x_hat = [0; L; 0; 0; 0; 0];

N = 13;
state_dim = length(x_hat);
X_i_iprev = zeros(6, N);

% Camera intrinsic parameters of ZED2 for 1280 x 720 resolution
fx = 720;  % Focal length in x
fy = 720;  % Focal length in y
cx = 640;  % Principal point x (center of the image)
cy = 360;  % Principal point y (center of the image)

% % Camera intrinsic parameters of D435 Realsense
% fx = 870.00;
% fy = 900.00;
% cx = 640.886;
% cy = 363.087;

% Camera intrinsic matrix - K
K = [fx, 0,  cx;
     0,  fy, cy;
     0,  0,  1];

% ZED 2 image dimensions
image_width = 1280;
image_height = 720;

% Define the radius of the sphere
r = 5;
n=6;
offset = -1; % In order to define the x-coordinate center value of dome

load('all_experiments_best_results.mat');

trajectory = Pendulum(0,L,0,0,0,0); 
target_point = Pendulum(0,L,0,0,0,0)'; 


% Number of experiments (adjust this if you add more experiments)
num_experiments = 49;  % Set this to your actual number of experiments

% Preallocate arrays for initial parameters and optimized parameters
initial_params = [];
experiments = [];

% Loop through each experiment and append parameters to the arrays
for i = 1:num_experiments
    % Generate the variable names dynamically
    initial_var_name = sprintf('experiment_%d.initial_parms', i);
    optimized_var_name = sprintf('experiment_%d.optimized_params', i);
    
   
        initial_params =[initial_params; eval(initial_var_name)];
        experiments = [experiments;eval(optimized_var_name)];
    
end

% Use the last experimentís parameters as default if needed
optimized_params = experiments(end, :);  % Last experiment optimized params
initial_parameters = initial_params(end, :);  % Last experiment initial params


% Initialize parameters
lambda_ = optimized_params(1)^2 * (n + kappa) - n;
wm = repmat(0.5 / (n + lambda_), 1, 2 * n + 1);
wm(1) = lambda_ / (n + lambda_);
wc = wm;
wc(1) = wc(1) + (1 - optimized_params(1)^2 + optimized_params(2));

% Set camera position
r = 5;
[X_cam, Y_cam, Z_cam] = get_camera_position(r, optimized_params(3), optimized_params(4));

% Update camera extrinsics or other parameters as needed
c_extr = current_extrinsic(X_cam, Y_cam, Z_cam);

% Generate noise
X_noise = sqrt(SIGMA_normal(1,1)) * randn(size(target_point(1,:)));
Y_noise = sqrt(SIGMA_normal(2,2)) * randn(size(target_point(2,:)));
Z_noise = sqrt(SIGMA_normal(3,3)) * randn(size(target_point(3,:)));

num_points = size(target_point, 2);

% Apply noise transformation
for i = 1:num_points
    noise_cam = [X_noise(i); Y_noise(i); Z_noise(i)];
    noise_world = c_extr(1:3, 1:3) * noise_cam;
    X_noise(i) = noise_world(1);
    Y_noise(i) = noise_world(2);
    Z_noise(i) = noise_world(3);
end

% Add the noise to the trajectory
X_noisy = target_point(1, :) + X_noise;
Y_noisy = target_point(2, :) + Y_noise;
Z_noisy = target_point(3, :) + Z_noise;

measurements = [X_noisy; Y_noisy; Z_noisy]';

% Initialize variables
x_hat = [0; L; 0; 0; 0; 0];
% Generate the target point trajectory
target_point = Pendulum(0, L, 0, 0, 0, 0)';

num_points = size(target_point, 2);
target_points_hom = [target_point(1:3, :); ones(1, num_points)];

final_estimations = zeros(num_points, 3);
final_estimations(1, :) = x_hat(1:3)';

P = Q;
total_cost = 0;

% Run UKF over all time steps
for k = 2:num_points
    % Measurement prediction
    % Project the point onto the image plane using the intrinsic matrix
    projected_point = inv(c_extr) * target_points_hom(:, k);
    
    % Project the 3D point onto the 2D pixel plane
    pixelCoords = K * projected_point(1:3);
    
    if pixelCoords(3) >= 0
        % Normalize to get pixel coordinates
        pixelCoords = pixelCoords / pixelCoords(3);
        u = pixelCoords(1);
        v = pixelCoords(2);
        
        % Check if the point is within the image boundaries
        if (0 <= u) && (u <= image_width) && (0 <= v) && (v <= image_height)
            SIGMA = SIGMA_normal;
        else
            SIGMA = increased_SIGMA;
        end
        
        if k == 2
            P = Q;
        end
        
        % PREDICT STAGE
        X = sigmaPointsUKF(state_dim, x_hat, P, optimized_params(1));  % Sigma points
        
        % SIGMA POINTS PROPAGATION
        for o = 1:N
            % Assuming F_x can accept X(:, o) as input and returns a column vector
            X_i_iprev(:, o) = F_x(X(:, o), Qdiag);
        end
        
        % MEAN AND COVARIANCE COMPUTATION
        x_hat_i_iprev = X_i_iprev * wm';
        Pi_iprev = (X_i_iprev - x_hat_i_iprev) * diag(wc) * (X_i_iprev - x_hat_i_iprev)' + Q;
        
        % UPDATE STAGE
        ZHTA = X_i_iprev(1:3, :);  % Sigma in measurement space
        zhta_tilda = ZHTA * wm';  % Mean measurement
        
        % Compute covariance in measurement space
        Pz = (ZHTA - zhta_tilda) * diag(wc) * (ZHTA - zhta_tilda)' + ...
             c_extr(1:3, 1:3) * SIGMA * c_extr(1:3, 1:3)';
        
        % Compute the cross-covariance of the state and the measurement
        Pxz = (X_i_iprev - x_hat_i_iprev) * diag(wc) * (ZHTA - zhta_tilda)';
        
        KALMAN_GAIN = Pxz / Pz;
        
        % Update estimate with measurement
        x_hat = x_hat_i_iprev + KALMAN_GAIN * (measurements(k, :)' - zhta_tilda);
        final_estimations(k, :) = x_hat(1:3)';
        P = Pi_iprev - KALMAN_GAIN * Pz * KALMAN_GAIN';
    end
end

measurements_after = measurements;

% MATLAB code equivalent to the provided Python code

% Assuming that the variables trajectory, measurements_before, measurements_after,
% initial_estimations, final_estimations, etc., are already defined in your workspace.

% %% Setup for the 3D plot
% figure;
% ax = axes;
% title('Camera Motion Animation with Moving Target on Hemispherical Dome');
% xlabel('X');
% ylabel('Y');
% zlabel('Z');
% grid on;
% axis equal;


% Initialize parameters
lambda_ = initial_parameters(1)^2 * (n + kappa) - n;
wm = repmat(0.5 / (n + lambda_), 1, 2 * n + 1);
wm(1) = lambda_ / (n + lambda_);
wc = wm;
wc(1) = wc(1) + (1 - initial_parameters(1)^2 + initial_parameters(2));

% Set camera position
r = 5;
[X_cam, Y_cam, Z_cam] = get_camera_position(r, initial_parameters(3), initial_parameters(4));

% Update camera extrinsics or other parameters as needed
c_extr = current_extrinsic(X_cam, Y_cam, Z_cam);

% Generate noise
X_noise = sqrt(SIGMA_normal(1,1)) * randn(size(target_point(1, :)));
Y_noise = sqrt(SIGMA_normal(2,2)) * randn(size(target_point(2, :)));
Z_noise = sqrt(SIGMA_normal(3,3)) * randn(size(target_point(3, :)));

num_points = size(target_point, 2);

% Apply noise transformation
for i = 1:num_points
    noise_cam = [X_noise(i); Y_noise(i); Z_noise(i)];
    noise_world = c_extr(1:3, 1:3) * noise_cam;
    X_noise(i) = noise_world(1);
    Y_noise(i) = noise_world(2);
    Z_noise(i) = noise_world(3);
end

% Add the noise to the trajectory
X_noisy = target_point(1, :) + X_noise;
Y_noisy = target_point(2, :) + Y_noise;
Z_noisy = target_point(3, :) + Z_noise;

measurements = [X_noisy; Y_noisy; Z_noisy]';

% Initialize variables
x_hat = [0; L; 0; 0; 0; 0];
% Generate the target point trajectory
target_point = Pendulum(0, L, 0, 0, 0, 0)';

num_points = size(target_point, 2);
target_points_hom = [target_point(1:3, :); ones(1, num_points)];

initial_estimations = zeros(num_points, 3);
initial_estimations(1, :) = x_hat(1:3)';

outliers_before = -1 * ones(num_points, 1);
P = Q;
total_cost = 0;
counter = 0;

% Run UKF over all time steps
for k = 2:num_points
    % Measurement prediction
    % Project the point onto the image plane using the intrinsic matrix
    projected_point = inv(c_extr) * target_points_hom(:, k);

    % Project the 3D point onto the 2D pixel plane
    pixelCoords = K * projected_point(1:3);

    if pixelCoords(3) >= 0
        % Normalize to get pixel coordinates
        pixelCoords = pixelCoords / pixelCoords(3);
        u = pixelCoords(1);
        v = pixelCoords(2);
        % Check if the point is within the image boundaries
        if (0 <= u) && (u <= image_width) && (0 <= v) && (v <= image_height)
            SIGMA = SIGMA_normal;
        else
            SIGMA = increased_SIGMA;
            outliers_before(k) = k;
            counter = counter + 1;
            fprintf('u = %f, v = %f\n', u, v);
            fprintf('projected_point(1:3) = [%f, %f, %f]\n', projected_point(1), projected_point(2), projected_point(3));
            fprintf('c_extr = \n');
            disp(c_extr);
            fprintf('target_points_hom(:, k) = \n');
            disp(target_points_hom(:, k));
            fprintf('X_cam = %f\n', X_cam);
        end

        if k == 2
            P = Q;
        end

        % PREDICT STAGE
        X = sigmaPointsUKF(state_dim, x_hat, P, initial_parameters(1));  % Sigma points

        % SIGMA POINTS PROPAGATION
        for o = 1:N
            % Assuming F_x accepts X(:, o) as input and returns a column vector
            X_i_iprev(:, o) = F_x(X(:, o), Qdiag);
        end

        % MEAN AND COVARIANCE COMPUTATION
        x_hat_i_iprev = X_i_iprev * wm';
        Pi_iprev = (X_i_iprev - x_hat_i_iprev) * diag(wc) * (X_i_iprev - x_hat_i_iprev)' + Q;

        % UPDATE STAGE
        ZHTA = X_i_iprev(1:3, :);  % Sigma in measurement space
        zhta_tilda = ZHTA * wm';   % Mean measurement

        % Compute covariance in measurement space
        Pz = (ZHTA - zhta_tilda) * diag(wc) * (ZHTA - zhta_tilda)' + ...
             c_extr(1:3, 1:3) * SIGMA * c_extr(1:3, 1:3)';

        % Compute the cross-covariance of the state and the measurement
        Pxz = (X_i_iprev - x_hat_i_iprev) * diag(wc) * (ZHTA - zhta_tilda)';

        KALMAN_GAIN = Pxz / Pz;

        % Update estimate with measurement
        x_hat = x_hat_i_iprev + KALMAN_GAIN * (measurements(k, :)' - zhta_tilda);
        initial_estimations(k, :) = x_hat(1:3)';
        P = Pi_iprev - KALMAN_GAIN * Pz * KALMAN_GAIN';
    end
end

measurements_before = measurements;





%% Create subplots: 4x1 layout
t=0:0.033:3;
fig=figure;
% First subplot: Pendulum X Position
subplot(4,1,1);
plot(t,trajectory(:,1), 'k', 'LineWidth', 1); hold on;
plot(t,measurements_before(:,1), 'b--', 'LineWidth', 1);
plot(t,initial_estimations(:,1), 'b', 'LineWidth', 1);
plot(t,measurements_after(:,1), 'r--', 'LineWidth', 1);
plot(t,final_estimations(:,1), 'r', 'LineWidth', 1);
hold off;
grid on;
ylabel('$p_x(t)$ [m]', 'Interpreter', 'latex','FontSize', 10);
legend({'$\mathbf{p}(t)$', '$\mathbf{y}(t)$ (no opt.)', '$\mathbf{H}\hat{\mathbf{x}}_{k,k}(t)$ (no opt.)', '$\mathbf{y}(t)$ (optimized)', '$\mathbf{H}\hat{\mathbf{x}}_{k,k}(t)$ (optimized)'}, ...
    'Location', 'northoutside', 'Orientation', 'vertical','Interpreter', 'latex', 'FontSize', 10);

% Second subplot: Pendulum Y Position
subplot(4,1,2);
plot(t,trajectory(:,2), 'k', 'LineWidth', 1); hold on;
plot(t,measurements_before(:,2), 'b--', 'LineWidth', 1);
plot(t,initial_estimations(:,2), 'b', 'LineWidth', 1);
plot(t,measurements_after(:,2), 'r--', 'LineWidth', 1);
plot(t,final_estimations(:,2), 'r', 'LineWidth', 1);
hold off;
grid on;
ylabel('$p_y(t)$ [m]','Interpreter', 'latex','FontSize', 10);
% Optionally add legend if desired
% legend({'Ground Truth', 'Measurements Before', 'UKF Before', 'Measurements After', 'UKF After'}, 'FontSize', 8);

% Third subplot: Pendulum Z Position
subplot(4,1,3);
plot(t,trajectory(:,3), 'k', 'LineWidth', 1); hold on;
plot(t,measurements_before(:,3), 'b--', 'LineWidth', 1);
plot(t,initial_estimations(:,3), 'b', 'LineWidth', 1);
plot(t,measurements_after(:,3), 'r--', 'LineWidth', 1);
plot(t,final_estimations(:,3), 'r', 'LineWidth', 1);
hold off;
grid on;
ylabel('$p_z(t)$ [m]','Interpreter', 'latex', 'FontSize', 10);
% Optionally add legend if desired
% legend({'Ground Truth', 'Measurements Before', 'UKF Before', 'Measurements After', 'UKF After'}, 'FontSize', 8);

% Calculate cumulative errors for final and initial estimations
final_error = sqrt((trajectory(:,1) - final_estimations(:,1)).^2 + ...
                   (trajectory(:,2) - final_estimations(:,2)).^2 + ...
                   (trajectory(:,3) - final_estimations(:,3)).^2);

initial_error = sqrt((trajectory(:,1) - initial_estimations(:,1)).^2 + ...
                     (trajectory(:,2) - initial_estimations(:,2)).^2 + ...
                     (trajectory(:,3) - initial_estimations(:,3)).^2);

% Fourth subplot: Cumulative Error
subplot(4,1,4);
plot(t,final_error, 'r', 'LineWidth', 1); hold on;
plot(t,initial_error, 'b', 'LineWidth', 1);
hold off;
setLegendFontSize(fig, 12);
box on;
grid on;
xlabel('Time [sec]','Interpreter', 'latex','FontSize',10);
ylabel('$\|\mathbf{p}-\mathbf{H}\hat{\mathbf{x}}_{k,k}\|$ [m]','Interpreter', 'latex','FontSize',10);
legend({'Optimal Params', 'Arbitrary Params'}, 'Orientation', 'horizontal','Interpreter','latex','FontSize',12);

% Adjust layout if necessary (MATLAB adjusts automatically)

%% Plotting the hemispherical dome

r = 5;
offset = -1;

% Create mesh grid for spherical coordinates (theta, phi)
theta = linspace(0, 2*pi, 50);  % Angle around the z-axis (azimuth)
phi = linspace(0, pi/2, 25);    % Angle from the z-axis (elevation, upper half)

[Theta, Phi] = meshgrid(theta, phi);

% Parametric equations for the hemisphere in Cartesian coordinates
X_position_of_lens = r * cos(Phi) + offset;
Y_position_of_lens = r * sin(Phi) .* cos(Theta);
Z_position_of_lens = r * sin(Phi) .* sin(Theta);

% % Plot the hemisphere
% surf(X_position_of_lens, Y_position_of_lens, Z_position_of_lens);
% shading interp;
% xlabel('X');
% ylabel('Y');
% zlabel('Z');
% title('Hemispherical Dome');
% grid on;
% axis equal;

% Initialize the figure and axes
fig2=figure;
ax = axes;
hold on;
grid on;

% Define the range of experiments
for exper = 1:49
    % Compute camera positions before optimization
    x_camera_before = r * cos(initial_params(exper, 3)) + offset;
    y_camera_before = r * sin(initial_params(exper, 3)) * cos(initial_params(exper, 4));
    z_camera_before = r * sin(initial_params(exper, 3)) * sin(initial_params(exper, 4));

    % Compute camera positions after optimization
    x_camera_after = r * cos(experiments(exper, 3)) + offset;
    y_camera_after = r * sin(experiments(exper, 3)) * cos(experiments(exper, 4));
    z_camera_after = r * sin(experiments(exper, 3)) * sin(experiments(exper, 4));

    % Target point at the origin
    targ_point = [0; 0; 0];

    % -------------------- Before Optimization --------------------

    % Forward vector (from camera to target)
    forward_vector_before = targ_point - [x_camera_before; y_camera_before; z_camera_before];
    forward_vector_before = forward_vector_before / norm(forward_vector_before);

    % Up vector (global up direction)
    up_vector_before = [0; 0; 1];

    % Right vector (cross product of up and forward vectors)
    right_vector_before = cross(up_vector_before, forward_vector_before);
    right_vector_before = right_vector_before / norm(right_vector_before);

    % Recalculate up vector to ensure orthogonality
    up_vector_before = cross(forward_vector_before, right_vector_before);

    % Scale vectors for visualization
    scale = 1;
    right_vector_before = right_vector_before * scale;
    up_vector_before = up_vector_before * scale;
    forward_vector_before = forward_vector_before * scale;

    % -------------------- After Optimization --------------------

    % Forward vector (from camera to target)
    forward_vector_after = targ_point - [x_camera_after; y_camera_after; z_camera_after];
    forward_vector_after = forward_vector_after / norm(forward_vector_after);

    % Up vector (global up direction)
    up_vector_after = [0; 0; 1];

    % Right vector (cross product of up and forward vectors)
    right_vector_after = cross(up_vector_after, forward_vector_after);
    right_vector_after = right_vector_after / norm(right_vector_after);

    % Recalculate up vector to ensure orthogonality
    up_vector_after = cross(forward_vector_after, right_vector_after);

    % Scale vectors for visualization
    right_vector_after = right_vector_after * scale;
    up_vector_after = up_vector_after * scale;
    forward_vector_after = forward_vector_after * scale;

    % -------------------- Plotting --------------------

    % Plot the ground truth trajectory (only once)

    % Plot camera positions before optimization
    if exper == 1
        h1=scatter3(x_camera_before, y_camera_before, z_camera_before, 50, 'y', 'filled');
    legend(h1,'$\mathbf{p}_s$ for $\mathbf{\xi}_0$', 'Interpreter', 'latex');
    else
        scatter3(x_camera_before, y_camera_before, z_camera_before, 50, 'y', 'filled');
    end
    text(x_camera_before, y_camera_before, z_camera_before, num2str(exper), 'Color', 'black', 'FontSize', 12, 'FontWeight', 'bold');
    % Plot camera orientation vectors before optimization
%     h2 = quiver3(x_camera_before, y_camera_before, z_camera_before, right_vector_before(1), right_vector_before(2), ...
%     right_vector_before(3), 'g', 'LineWidth', 1); % Simple DisplayName for quiver3
%     legend(h2,'$x$-axis of $\{S\}$', 'Interpreter', 'latex');
%     h3=quiver3(x_camera_before, y_camera_before, z_camera_before, up_vector_before(1), up_vector_before(2), up_vector_before(3), 'b','LineWidth', 1);
%     legend(h3,'$y$-axis of $\{S\}$', 'Interpreter', 'latex');
    h4=quiver3(x_camera_before, y_camera_before, z_camera_before, forward_vector_before(1), forward_vector_before(2), forward_vector_before(3), 'r','LineWidth', 1);
    legend(h4,'$z$-axis of $\{S\}$', 'Interpreter', 'latex');
    % Plot camera positions after optimization
    if exper == 1
        h5=scatter3(x_camera_after, y_camera_after, z_camera_after, 50,'r', 'p', 'LineWidth', 2.5);
        legend(h5,'$\mathbf{p}_s$ for $\mathbf{\xi}^*$', 'Interpreter', 'latex');
    else
        scatter3(x_camera_after, y_camera_after, z_camera_after, 50, 'r', 'p', 'LineWidth', 2.5);
    end
    text(x_camera_after, y_camera_after, z_camera_after, num2str(exper), 'Color', 'black', 'FontSize', 12, 'FontWeight', 'bold');
    
    % Plot camera orientation vectors after optimization
%     quiver3(x_camera_after, y_camera_after, z_camera_after, right_vector_after(1), right_vector_after(2), right_vector_after(3), 'g','LineWidth', 1);
%     quiver3(x_camera_after, y_camera_after, z_camera_after, up_vector_after(1), up_vector_after(2), up_vector_after(3), 'b', 'LineWidth', 1);
%     quiver3(x_camera_after, y_camera_after, z_camera_after, forward_vector_after(1), forward_vector_after(2), forward_vector_after(3), 'r', 'LineWidth', 1);

    % Plot initial outliers if any
    for i = 1:num_points
        if outliers_before(i) >= 0
            scatter3(initial_estimations(outliers_before(i), 1), initial_estimations(outliers_before(i), 2), initial_estimations(outliers_before(i), 3), 'MarkerEdgeColor', 'k', 'MarkerFaceColor', 'm', 'DisplayName', 'Initial Outliers','Interpreter', 'latex');
        end
    end
end
h9=plot3(trajectory(:, 1), trajectory(:, 2), trajectory(:, 3), 'k', 'LineWidth', 2);
legend(h9,'$Ground Truth$', 'Interpreter', 'latex');
% Plot the hemispherical surface
red_color = [0.8, 0.5, 0.5];  % Muted red RGB values
surf(X_position_of_lens, Y_position_of_lens, Z_position_of_lens, 'FaceColor', red_color, 'EdgeColor', 'none', 'FaceAlpha', 0.5);

% Set labels and title
xlabel('$x$ [m]' ,'Interpreter', 'latex');
ylabel('$y$ [m]', 'Interpreter', 'latex');
zlabel('$z$ [m]', 'Interpreter', 'latex');
%title('Camera Position and Orientation on Hemisphere');
% Add specific handles to legend
%legend([h1,h2,h3, h4,h5,h9]);
legend([h1, h4,h5,h9]);
setLegendFontSize(fig2, 12);
legend('show');
% Adjust axis properties
axis equal;
box on;

xlim([-r-1, r+1]);
ylim([-r-1, r+1]);
zlim([-r-1, r+1]);

% your plotting code here

% Display the plot
hold off;


