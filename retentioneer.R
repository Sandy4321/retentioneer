library("ggplot2")

kSecondsPerDay <- 60 * 60 * 24

# These are the days we want to measure the retention for
days <- c(1, 3, 7, 14, 30, 60, 90)

AnalyzeRetention <- function(file, sep = ",", cohort.units = "months",
	min.cohort.users = 20, method = "on-or-after", show.legend = TRUE,
	avg.only = FALSE) {
	# Analyzes a CSV file of user activities and plots the retention over time
	#
	# Args:
	#   file: The location of the CSV file containing the user activity data.
	#   sep: The separator used to separate the user id and date in the CSV file.
	#     Default is ",".
	#   cohort.units: How to determine the cohorts: "months" or "years". Default
	#     is "months".
	#   method: How to determine whether a user was retained for n-days. If set
	#     to "on", a user will have to have been active on a specific date. If
	#     set to "on-or-after" the user is retained if they're active on or after
	#     a specific date. Default is "on-or-after".
	#   min.cohort.users: The minimum number of users who signed up in a cohort
	#     in order to display it in the plot. Default is 20.
	#   show.legend: Whether to show a legend on the plot. Default is TRUE.
	#   avg.only: Whether or not to just plot the average retention rate for the
	#     all of the data regardless of signup cohort. Default is FALSE.
	if (! cohort.units %in% c("months", "years")) {
		stop("cohort.units must be months or years")
	}

	if (! method %in% c("on", "on-or-after")) {
		stop("method must be 'on' or 'on-or-after'")
	}

	# Ensure we include the zero day retention counts which are needed to
	# calculate the retention rate for the other days
	days <- sort(unique(c(0, days)))

	# We'll use the file's modified date when determining whether the users in
	# each cohort have enough data to display in the chart
	file.mdate <- as.POSIXct(file.info(file)$mtime)

	activities <- LoadActivityData(file, sep, cohort.units)
	users <- GetUserSignupCohorts(activities)
	signup.cohorts <- sort(unique(users$cohort))

	retention.cohorts <- vector()
	retention.days.retained <- vector()
	retention.users.retained <- vector()

	# Display a progress bar while the analysis is taking place
	progress.bar <- txtProgressBar(min = 0, max = length(signup.cohorts),
		style = 3)

	# Determine the n-day retention for each signup month
	for (i in 1:length(signup.cohorts)) {
		signup.cohort <- signup.cohorts[i]
		signup.user.ids <- users[users$cohort == signup.cohort, "user.id"]

		# Some cohorts, such as those when the the service went into private
		# alpha, can have abnormally high retention rates due to those users being
		# comprised solely of the service's team
		if (length(signup.user.ids) < min.cohort.users) {
			next
		}

		if (cohort.units == "months") {
			cohort.date <- as.POSIXct(paste(signup.cohort, "01", sep = "-"))
		} else if (cohort.units == "years") {
			cohort.date <- as.POSIXct(paste(signup.cohort, "01", "01", sep = "-"))
		}

		possible.activities <- subset(activities, date >= cohort.date)

		# Figure out how many users in this cohort were retained for n-days

		# First, initialize the retention counts.
		# If it's not possible for a user to be retained for n-days because n-days
		# haven't elapsed yet, set the count to NA so we can skip it for the chart
		retention.counts <- list()
		for (day in days) {

			# Note that list component names can't be integers, which is why we
			# convert the number of days into characters first
			key <- DayToKey(day)

			if (cohort.date + kSecondsPerDay * day >= file.mdate) {
				# If none of the users in the cohort have had an opportunity to be
				# retained for n days as of the time of the activity export, then
				# don't display zero-retention on the chart for that retention period
				retention.counts[[key]] <- NA
			} else {
				retention.counts[[key]] <- 0
			}
		}

		# Then iterate over each user in the cohort and tally up how many were
		# retained for at least n-days
		for (signup.user.id in signup.user.ids) {
			days.retained <- GetDaysRetained(signup.user.id, possible.activities)
			for (day in days) {
				if (method == "on") {
					was.retained = any(days.retained == day)
				} else if (method == "on-or-after") {
					was.retained = any(days.retained >= day)
				}

				if (was.retained) {
					key <- DayToKey(day)
					retention.counts[[key]] <- retention.counts[[key]] + 1
				}
			}
		}

		# Keep track of the results so we can construct the final data frame after
		# we've iterated over all of the cohorts/users/days-retained
		for (day in days) {
			users.retained <- retention.counts[[DayToKey(day)]]
			retention.cohorts <- c(retention.cohorts, signup.cohort)
			retention.days.retained <- c(retention.days.retained, day)
			retention.users.retained <- c(retention.users.retained, users.retained)
		}

		# Display the progress
		setTxtProgressBar(progress.bar, i)
	}

	close(progress.bar)

	# Now that we've collected all of the data, combine it into a single data
	# frame that we can then pass to ggplot
	retention.data <- data.frame(cohort = retention.cohorts,
		days.retained = retention.days.retained,
		users.retained = retention.users.retained)

	# Remove rows that don't have full data due to the CSV file being created
	# less than n days since the user signed up
	retention.data <- retention.data[complete.cases(retention.data), ]

	# Add a column showing the retention rate for each day within each cohort
	if (avg.only) {
		retention.data <- aggregate(users.retained ~ days.retained,
			retention.data, sum)
		day.zero.counts <- max(retention.data$users.retained)
		retention.data$retention.rate <- (retention.data$users.retained /
			day.zero.counts) * 100
	} else {
		cohorts.initial <- aggregate(users.retained ~ cohort, retention.data, max)
		retention.data$retention.rate <- (retention.data$users.retained /
			cohorts.initial[retention.data$cohort, "users.retained"]) * 100
	}

	# Make this available in the parent environment for additional analysis
	retention.data <<- retention.data

	# Print the data for you to explore
	print(retention.data)

	# Finally, plot the retention data
	if (avg.only) {
		PlotAverageRetention(retention.data)
	} else {
		PlotRetentionByCohort(retention.data, show.legend)
	}
}

LoadActivityData <- function(file, sep = ",", cohort.units) {
	# Loads and prepares activity data from a CSV file
	#
	# Args:
	#   file: The path of the CSV file
	#   sep: The separator used in the CSV file. Default is ",".
	#   cohort.units: How to determine the cohorts: "months" or "years"
	#
	# Returns:
	#   A data frame containg user.id, date, and cohort
	cohort.format <- GetCohortFormat(cohort.units)
	activities <- read.csv(file, sep = sep,
		col.names = c("user.id", "timestamp"), header = FALSE)
	activities$date <- as.POSIXlt(activities$timestamp, origin = "1970-01-01")
	activities$cohort <- format(activities$date, cohort.format)
	activities
}

GetCohortFormat <- function(cohort.units) {
	# Determines the format of the cohorts based on the specified unit
	#
	# Args:
	#   cohort.units: How to determine the cohorts: "months" or "years"
	#
	# Returns:
	#   A character string that determines how the date will be formatted
	if (cohort.units == "months") {
		"%Y-%m"
	} else if (cohort.units == "years") {
		"%Y"
	}
}

GetUserSignupCohorts <- function(activities) {
	# Determines which cohort each user belongs to based on his first activity
	#
	# Args:
	#   activities: The data frame of activities containing user.id and cohort
	#
	# Returns:
	#   A data frame containing the signup cohort for each user id
	aggregate(cohort ~ user.id, activities, min)
}

GetDaysRetained <- function(target.user.id, activities) {
	# Determines how many days a specific user was retained
	#
	# Args:
	#   target.user.id: The id of the user we want to analyze
	#   activities: A data frame containing user ids and activity dates
	#
	# Returns:
	#   A vector containing how many days after signup a user was retained
	user.activities <- subset(activities, user.id == target.user.id, "date")
	user.signup.date <- min(user.activities$date)
	floor(difftime(user.activities$date, user.signup.date, units = "days"))
}

DayToKey <- function(day) {
	# Converts an integer into a character so it can be used as a list component
	#
	# Args:
	#   day: The number of days we're going to analyze retention for.
	#
	# Returns:
	#   A character string. Ex: "day.1".
	paste("day", day, sep = ".")
}

PlotRetentionByCohort <- function(retention.data, show.legend) {
	# Plots the retention data by cohort
	#
	# Args:
	#   retention.data: A data frame containing days.retained, retention.rate,
	#     and cohort
	#   show.legend: Whether or not to show a legend on the plot.
	g <- ggplot(retention.data,
		aes(x = days.retained, y = retention.rate, group = cohort, color = cohort))
	g <- g + scale_x_continuous(breaks = days)
	g <- g + geom_line(size = 1.5)
	g <- g + labs(x = "Days Since Sign Up", y = "Percentage of Users Still Active")
	g <- g + ggtitle("Retention Curve by Sign Up Cohort")
	g <- g + theme(plot.title = element_text(lineheight = 1.2, face = "bold",
		size = rel(1.5)))
	g <- g + theme(axis.ticks = element_blank())
	g <- g + theme(plot.background = element_rect(fill = "#F6F8FA"))
	g <- g + theme(panel.background = element_blank())
	g <- g + theme(panel.grid.major = element_line(color = "#DDDDDD",
		size = 0.2))

	if (! show.legend) {
		g <- g + theme(legend.position = "none")
	}

	# Call print so that the g is rendered in RStudio
	print(g)
}

PlotAverageRetention <- function(retention.data) {
	# Plots the average retention rate for the data
	#
	# Args:
	#   retention.data: A data frame containing days.retained and retention.rate
	g <- ggplot(retention.data,
		aes(x = days.retained, y = retention.rate))
	g <- g + scale_x_continuous(breaks = days)
	g <- g + geom_line(size = 1.5, color = "#5BB5E6")
	g <- g + labs(x = "Days Since Sign Up", y = "Percentage of Users Still Active")
	g <- g + ggtitle("Retention Curve")
	g <- g + theme(plot.title = element_text(lineheight = 1.2, face = "bold",
		size = rel(1.5)))
	g <- g + theme(axis.ticks = element_blank())
	g <- g + theme(plot.background = element_rect(fill = "#F6F8FA"))
	g <- g + theme(panel.background = element_blank())
	g <- g + theme(panel.grid.major = element_line(color = "#DDDDDD",
		size = 0.2))

	print(g)
}

AnalyzeRetention("data/test-data.csv", cohort.units = "months")
